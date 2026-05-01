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
          unless result.is_a?(DAG::Effects::HandlerResult)
            raise ArgumentError, "result must be DAG::Effects::HandlerResult"
          end
          raise ArgumentError, "error must be Hash or nil" unless error.nil? || error.is_a?(Hash)
          DAG.json_safe!(error, "$root.error")

          super(result: result, error: immutable_json_copy(error))
        end

        private

        def immutable_json_copy(value)
          return nil if value.nil?
          return value if value.frozen?

          DAG.deep_freeze(DAG.deep_dup(value))
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
          raise ArgumentError, "released must be an Array" unless released.is_a?(Array)
          raise ArgumentError, "error must be Hash or nil" unless error.nil? || error.is_a?(Hash)
          DAG.json_safe!(released, "$root.released")
          DAG.json_safe!(error, "$root.error")

          super(
            succeeded_record: succeeded_record,
            failed_record: failed_record,
            released: DAG.deep_freeze(DAG.deep_dup(released)),
            error: immutable_json_copy(error)
          )
        end

        private

        def validate_optional_record!(value, label)
          return if value.nil? || value.is_a?(DAG::Effects::Record)

          raise ArgumentError, "#{label} must be DAG::Effects::Record or nil"
        end

        def immutable_json_copy(value)
          return nil if value.nil?
          return value if value.frozen?

          DAG.deep_freeze(DAG.deep_dup(value))
        end
      end
      private_constant :DispatchOutcome

      # @param storage [DAG::Ports::Storage]
      # @param handlers [Hash{String,Symbol=>#call}] maps effect type to handler
      # @param clock [#now_ms]
      # @param owner_id [String]
      # @param lease_ms [Integer]
      # @param unknown_handler_policy [:terminal_failure, :raise]
      def initialize(storage:, handlers:, clock:, owner_id:, lease_ms:, unknown_handler_policy: :terminal_failure)
        validate_storage!(storage)
        validate_dependency!(clock, :now_ms, "clock")
        validate_owner_id!(owner_id)
        validate_positive_integer!(lease_ms, "lease_ms")
        validate_unknown_handler_policy!(unknown_handler_policy)

        @storage = storage
        @handlers = normalize_handlers(handlers)
        @clock = clock
        @owner_id = owner_id
        @lease_ms = lease_ms
        @unknown_handler_policy = unknown_handler_policy
        freeze
      end

      # Claim and dispatch up to `limit` ready effects.
      # @param limit [Integer]
      # @return [DAG::Effects::DispatchReport]
      def tick(limit:)
        validate_nonnegative_integer!(limit, "limit")

        now_ms = @clock.now_ms
        claimed = @storage.claim_ready_effects(
          limit: limit,
          owner_id: @owner_id,
          lease_ms: @lease_ms,
          now_ms: now_ms
        )
        outcomes = claimed.map { |record| dispatch_record(record, now_ms) }

        DispatchReport[
          claimed: claimed,
          succeeded: outcomes.map(&:succeeded_record).compact,
          failed: outcomes.map(&:failed_record).compact,
          released: outcomes.flat_map(&:released),
          errors: outcomes.map(&:error).compact
        ]
      end

      private

      def dispatch_record(record, now_ms)
        outcome = handler_outcome_for(record)
        apply_handler_result(record, outcome.result, now_ms, outcome.error)
      rescue DAG::Effects::StaleLeaseError => stale
        DispatchOutcome.claimed_not_marked(error: stale_lease_error(record, stale))
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
          updated = @storage.mark_effect_succeeded(
            effect_id: record.id,
            owner_id: @owner_id,
            result: result.result,
            external_ref: result.external_ref,
            now_ms: now_ms
          )
          DispatchOutcome.succeeded(
            record: updated,
            released: release_if_terminal(updated, now_ms),
            error: error
          )
        else
          updated = @storage.mark_effect_failed(
            effect_id: record.id,
            owner_id: @owner_id,
            error: result.error,
            retriable: result.retriable?,
            not_before_ms: result.not_before_ms,
            now_ms: now_ms
          )
          DispatchOutcome.failed(
            record: updated,
            released: release_if_terminal(updated, now_ms),
            error: error
          )
        end
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
        raise ArgumentError, "handlers must be a Hash" unless handlers.is_a?(Hash)

        keys = handlers.keys.map(&:to_s)
        if keys.uniq.size != keys.size
          raise ArgumentError, "handlers contain duplicate effect types after String coercion"
        end
        handlers.each do |type, handler|
          validate_handler_type!(type)
          validate_dependency!(handler, :call, "handler #{type.inspect}")
        end

        handlers.to_h { |type, handler| [type.to_s, handler] }.freeze
      end

      def validate_storage!(value)
        %i[
          claim_ready_effects
          mark_effect_succeeded
          mark_effect_failed
          release_nodes_satisfied_by_effect
        ].each do |method_name|
          validate_dependency!(value, method_name, "storage")
        end
      end

      def validate_handler_type!(value)
        return if value.is_a?(String) || value.is_a?(Symbol)

        raise ArgumentError, "handler type must be String or Symbol"
      end

      def validate_unknown_handler_policy!(value)
        return if UNKNOWN_HANDLER_POLICIES.include?(value)

        raise ArgumentError, "unknown_handler_policy must be one of #{UNKNOWN_HANDLER_POLICIES.inspect}"
      end

      def validate_dependency!(value, method_name, label)
        return if value.respond_to?(method_name)

        raise ArgumentError, "#{label} must respond to #{method_name}"
      end

      def validate_owner_id!(value)
        raise ArgumentError, "owner_id must be String" unless value.is_a?(String)
        raise ArgumentError, "owner_id must not be empty" if value.empty?
      end

      def validate_positive_integer!(value, label)
        raise ArgumentError, "#{label} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
      end

      def validate_nonnegative_integer!(value, label)
        raise ArgumentError, "#{label} must be a non-negative Integer" unless value.is_a?(Integer) && !value.negative?
      end
    end
  end
end
