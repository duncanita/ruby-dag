# frozen_string_literal: true

module DAG
  module Effects
    # Claims durable abstract effects and routes them to consumer handlers.
    # The dispatcher owns coordination only: concrete side effects remain in
    # handler objects supplied by the application boundary.
    # @api public
    class Dispatcher
      # Accepted policies for records whose effect type has no handler.
      UNKNOWN_HANDLER_POLICIES = %i[terminal_failure raise].freeze

      # Private short-lived carrier returned by handler boundary normalization.
      # It keeps the handler-result invariant explicit where raw positional
      # tuples would make the boundary ambiguous.
      HandlerOutcome = Data.define(:result, :error) do
        class << self
          remove_method :[]

          # @param result [DAG::Effects::HandlerResult]
          # @param error [Hash, nil]
          # @return [HandlerOutcome]
          def [](result:, error:)
            new(result: result, error: error)
          end
        end

        # @param result [DAG::Effects::HandlerResult]
        # @param error [Hash, nil]
        def initialize(result:, error:)
          DAG::Validation.instance!(result, DAG::Effects::HandlerResult, "result")
          DAG::Validation.optional_hash!(error, "error")
          DAG.json_safe!(error, "$root.error")

          super(result: result, error: DAG::Effects.frozen_copy_or_nil(error))
        end
      end
      private_constant :HandlerOutcome

      # Private validated carrier for one claimed effect dispatch.
      DispatchOutcome = Data.define(:succeeded_record, :failed_record, :released, :error) do
        class << self
          # @param record [DAG::Effects::Record]
          # @param released [Array<Hash>]
          # @param error [Hash, nil]
          # @return [DispatchOutcome]
          def succeeded(record:, released:, error:)
            new(succeeded_record: record, failed_record: nil, released: released, error: error)
          end

          # @param record [DAG::Effects::Record]
          # @param released [Array<Hash>]
          # @param error [Hash, nil]
          # @return [DispatchOutcome]
          def failed(record:, released:, error:)
            new(succeeded_record: nil, failed_record: record, released: released, error: error)
          end

          # Build an outcome for a record that was claimed, but could not be
          # marked because the storage lease was already stale.
          # @param error [Hash]
          # @return [DispatchOutcome]
          def claimed_not_marked(error:)
            new(succeeded_record: nil, failed_record: nil, released: [], error: error)
          end
        end

        # @param succeeded_record [DAG::Effects::Record, nil]
        # @param failed_record [DAG::Effects::Record, nil]
        # @param released [Array<Hash>]
        # @param error [Hash, nil]
        def initialize(succeeded_record:, failed_record:, released:, error:)
          validate_optional_record!(succeeded_record, "succeeded_record")
          validate_optional_record!(failed_record, "failed_record")
          if succeeded_record && failed_record
            raise ArgumentError, "dispatch outcome cannot contain both succeeded_record and failed_record"
          end
          DAG::Validation.array!(released, "released")
          DAG::Validation.optional_hash!(error, "error")
          DAG.json_safe!(released, "$root.released")
          DAG.json_safe!(error, "$root.error")

          super(
            succeeded_record: succeeded_record,
            failed_record: failed_record,
            released: DAG.frozen_copy(released),
            error: DAG::Effects.frozen_copy_or_nil(error)
          )
        end

        private

        def validate_optional_record!(value, label)
          DAG::Validation.optional_instance!(value, DAG::Effects::Record, label)
        end
      end
      private_constant :DispatchOutcome

      # @param storage [DAG::Ports::Storage]
      # @param handlers [Hash{String,Symbol=>#call}] maps effect type to handler
      # @param clock [#now_ms]
      # @param owner_id [String]
      # @param lease_ms [Integer]
      # @param unknown_handler_policy [:terminal_failure, :raise]
      # @param parallelism [Integer] worker pool size for parallel dispatch
      #   within a single `#tick`. Default `1` preserves the V1.2 serial
      #   contract bit-identical. Values `> 1` require a storage adapter
      #   that declares `#thread_safe_for_dispatch?` and answers truthy;
      #   `Memory::Storage` does not, so combining it with `parallelism > 1`
      #   raises `ArgumentError`.
      def initialize(storage:, handlers:, clock:, owner_id:, lease_ms:,
        unknown_handler_policy: :terminal_failure, parallelism: 1)
        validate_storage!(storage)
        DAG::Validation.dependency!(clock, :now_ms, "clock")
        DAG::Validation.nonempty_string!(owner_id, "owner_id")
        DAG::Validation.positive_integer!(lease_ms, "lease_ms")
        DAG::Validation.positive_integer!(parallelism, "parallelism")
        validate_unknown_handler_policy!(unknown_handler_policy)
        validate_parallelism_storage!(storage, parallelism)

        @storage = storage
        @handlers = normalize_handlers(handlers)
        @clock = clock
        @owner_id = owner_id
        @lease_ms = lease_ms
        @unknown_handler_policy = unknown_handler_policy
        @parallelism = parallelism
        freeze
      end

      # Claim and dispatch up to `limit` ready effects.
      # @param limit [Integer]
      # @return [DAG::Effects::DispatchReport]
      def tick(limit:)
        DAG::Validation.nonnegative_integer!(limit, "limit")

        now_ms = @clock.now_ms
        claimed = @storage.claim_ready_effects(
          limit: limit,
          owner_id: @owner_id,
          lease_ms: @lease_ms,
          now_ms: now_ms
        )
        outcomes = parallel_map(claimed) { |record| dispatch_record(record) }

        DispatchReport[
          claimed: claimed,
          succeeded: outcomes.map(&:succeeded_record).compact,
          failed: outcomes.map(&:failed_record).compact,
          released: outcomes.flat_map(&:released),
          errors: outcomes.map(&:error).compact
        ]
      end

      private

      # Bounded-concurrency parallel map. At most `@parallelism` worker
      # threads in flight regardless of `items.length`. Result order
      # matches input order (slot-indexed writes; no shared mutation
      # otherwise). Unexpected exceptions raised inside a worker thread
      # re-emerge from `#tick` only after every worker has joined, so the
      # caller is guaranteed that no worker is still mutating storage
      # when `tick` raises.
      #
      # The exception path is *captured*, not *raised*, inside each
      # worker: `Thread#join` re-raises any exception that escaped a
      # worker thread, which would short-circuit the join loop and let
      # peer workers keep mutating storage past `tick`'s return. So each
      # worker rescues every exception, parks it in its own slot of the
      # `worker_errors` array (no contention: each worker writes a
      # different index), *drains the work queue* (so peer workers see
      # `ThreadError` on their next `pop` and exit instead of pulling
      # more records), and breaks out of the loop normally. Once every
      # worker has joined we raise the first captured exception.
      # Draining uses the queue itself as the abort signal, so
      # synchronization rides on `Queue`'s built-in thread-safety rather
      # than on Ruby's array-mutation visibility across threads.
      def parallel_map(items)
        return items.map { |item| yield item } if @parallelism <= 1 || items.length <= 1

        pool_size = (@parallelism < items.length) ? @parallelism : items.length
        results = Array.new(items.length)
        worker_errors = Array.new(pool_size)
        queue = Queue.new
        items.each_with_index { |item, idx| queue << [item, idx] }
        workers = Array.new(pool_size) do |worker_idx|
          Thread.new do
            loop do
              pair = begin
                queue.pop(true)
              rescue ThreadError
                break
              end
              item, idx = pair
              begin
                results[idx] = yield item
              rescue Exception => exception # standard:disable Lint/RescueException
                worker_errors[worker_idx] = exception
                drain_queue(queue)
                break
              end
            end
          end
        end
        workers.each(&:join)
        first_error = worker_errors.compact.first
        raise first_error if first_error

        results
      end

      # Empties `queue` non-blockingly. Used to signal peer workers to
      # stop pulling new records after a failure: any peer that calls
      # `queue.pop(true)` after a drain sees `ThreadError` and exits.
      # Records popped from the drain are deliberately discarded — they
      # remain in `:dispatching` state in storage; their leases will
      # expire and a future `tick` can re-claim them.
      def drain_queue(queue)
        loop do
          queue.pop(true)
        end
      rescue ThreadError
        # queue empty
      end

      def dispatch_record(record)
        outcome = handler_outcome_for(record)
        apply_handler_result(record, outcome.result, @clock.now_ms, outcome.error)
      rescue DAG::Effects::StaleLeaseError => stale
        emit_stale_lease_event(record, stale)
        DispatchOutcome.claimed_not_marked(error: stale_lease_error(record, stale))
      end

      def emit_stale_lease_event(record, stale)
        event = DAG::Event[
          type: :effect_dispatch_stale_lease,
          workflow_id: record.workflow_id,
          revision: record.revision,
          node_id: record.node_id,
          attempt_id: record.attempt_id,
          at_ms: @clock.now_ms,
          payload: {
            code: :stale_lease,
            effect_id: record.id,
            ref: record.ref,
            type: record.type,
            lease_owner: record.lease_owner,
            lease_until_ms: record.lease_until_ms,
            message: stale.message
          }
        ]
        @storage.append_event(workflow_id: record.workflow_id, event: event)
      end

      def handler_outcome_for(record)
        handler = @handlers[record.type]
        return unknown_handler_outcome(record) if handler.nil?

        invoke_handler(record, handler)
      end

      def invoke_handler(record, handler)
        result = handler.call(record)
        return HandlerOutcome[result: result, error: nil] if result.is_a?(DAG::Effects::HandlerResult)

        bad_return_outcome(record, result)
      rescue => caught
        raised_handler_outcome(record, caught)
      end

      def unknown_handler_outcome(record)
        if @unknown_handler_policy == :raise
          raise DAG::Effects::UnknownHandlerError, "no handler registered for effect type: #{record.type}"
        end

        error = effect_error(record, code: :unknown_handler)
        HandlerOutcome[
          result: DAG::Effects::HandlerResult.failed(error: error, retriable: false),
          error: error
        ]
      end

      def bad_return_outcome(record, result)
        error = effect_error(record, code: :handler_bad_return).merge(class: result.class.name)
        HandlerOutcome[
          result: DAG::Effects::HandlerResult.failed(error: error, retriable: true),
          error: error
        ]
      end

      def raised_handler_outcome(record, caught)
        error = effect_error(record, code: :handler_raised)
          .merge(class: caught.class.name, message: caught.message)
        HandlerOutcome[
          result: DAG::Effects::HandlerResult.failed(error: error, retriable: true),
          error: error
        ]
      end

      def apply_handler_result(record, result, now_ms, error)
        if result.success?
          completion = complete_effect_succeeded(record, result, now_ms)
          updated = completion.fetch(:record)
          DispatchOutcome.succeeded(
            record: updated,
            released: completion.fetch(:released),
            error: error
          )
        else
          completion = complete_effect_failed(record, result, now_ms)
          updated = completion.fetch(:record)
          DispatchOutcome.failed(
            record: updated,
            released: completion.fetch(:released),
            error: error
          )
        end
      end

      def complete_effect_succeeded(record, result, now_ms)
        if DAG::Ports::Storage.method_overridden?(@storage, :complete_effect_succeeded)
          return @storage.complete_effect_succeeded(
            effect_id: record.id,
            owner_id: @owner_id,
            result: result.result,
            external_ref: result.external_ref,
            now_ms: now_ms
          )
        end

        updated = @storage.mark_effect_succeeded(
          effect_id: record.id,
          owner_id: @owner_id,
          result: result.result,
          external_ref: result.external_ref,
          now_ms: now_ms
        )
        {record: updated, released: release_if_terminal(updated, now_ms)}
      end

      def complete_effect_failed(record, result, now_ms)
        if DAG::Ports::Storage.method_overridden?(@storage, :complete_effect_failed)
          return @storage.complete_effect_failed(
            effect_id: record.id,
            owner_id: @owner_id,
            error: result.error,
            retriable: result.retriable?,
            not_before_ms: result.not_before_ms,
            now_ms: now_ms
          )
        end

        updated = @storage.mark_effect_failed(
          effect_id: record.id,
          owner_id: @owner_id,
          error: result.error,
          retriable: result.retriable?,
          not_before_ms: result.not_before_ms,
          now_ms: now_ms
        )
        {record: updated, released: release_if_terminal(updated, now_ms)}
      end

      def release_if_terminal(updated, now_ms)
        return [] unless updated.terminal?

        @storage.release_nodes_satisfied_by_effect(effect_id: updated.id, now_ms: now_ms)
      end

      def stale_lease_error(record, error)
        effect_error(record, code: :stale_lease).merge(message: error.message)
      end

      def effect_error(record, code:)
        {
          code: code,
          effect_id: record.id,
          ref: record.ref,
          type: record.type
        }
      end

      def normalize_handlers(handlers)
        DAG::Validation.hash!(handlers, "handlers")

        keys = handlers.keys.map(&:to_s)
        if keys.uniq.size != keys.size
          raise ArgumentError, "handlers contain duplicate effect types after String coercion"
        end
        handlers.each do |type, handler|
          validate_handler_type!(type)
          DAG::Validation.dependency!(handler, :call, "handler #{type.inspect}")
        end

        handlers.to_h { |type, handler| [type.to_s, handler] }.freeze
      end

      def validate_storage!(value)
        %i[
          claim_ready_effects
          mark_effect_succeeded
          mark_effect_failed
          release_nodes_satisfied_by_effect
          append_event
        ].each do |method_name|
          DAG::Validation.dependency!(value, method_name, "storage")
        end
      end

      def validate_handler_type!(value)
        DAG::Validation.string_or_symbol!(value, "handler type")
      end

      def validate_unknown_handler_policy!(value)
        DAG::Validation.member!(value, UNKNOWN_HANDLER_POLICIES, "unknown_handler_policy")
      end

      def validate_parallelism_storage!(storage, parallelism)
        return if parallelism <= 1
        return if storage.respond_to?(:thread_safe_for_dispatch?) && storage.thread_safe_for_dispatch?

        raise ArgumentError,
          "parallelism > 1 requires a storage adapter that answers " \
          "thread_safe_for_dispatch? truthy; the configured adapter does not"
      end
    end
  end
end
