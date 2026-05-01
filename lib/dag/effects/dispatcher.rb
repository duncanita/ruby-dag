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

      # Private immutable accumulator used to fold one dispatch tick.
      DispatchAccumulator = Data.define(:succeeded, :failed, :released, :errors) do
        # @return [DispatchAccumulator]
        def self.empty
          new(succeeded: [], failed: [], released: [], errors: [])
        end

        # @param other [DispatchAccumulator]
        # @return [DispatchAccumulator]
        def plus(other)
          self.class.new(
            succeeded: succeeded + other.succeeded,
            failed: failed + other.failed,
            released: released + other.released,
            errors: errors + other.errors
          )
        end
      end
      private_constant :DispatchAccumulator

      HandlerCall = Data.define(:result, :error)
      private_constant :HandlerCall

      attr_reader :storage, :clock

      # @return [Hash{String=>#call}]
      attr_reader :handlers

      # @return [String]
      attr_reader :owner_id

      # @return [Integer]
      attr_reader :lease_ms

      # @return [:terminal_failure, :raise]
      attr_reader :unknown_handler_policy

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

        now_ms = clock.now_ms
        claimed = storage.claim_ready_effects(
          limit: limit,
          owner_id: owner_id,
          lease_ms: lease_ms,
          now_ms: now_ms
        )
        accumulator = claimed.reduce(DispatchAccumulator.empty) do |memo, record|
          memo.plus(dispatch_record(record, now_ms))
        end

        DispatchReport[
          claimed: claimed,
          succeeded: accumulator.succeeded,
          failed: accumulator.failed,
          released: accumulator.released,
          errors: accumulator.errors
        ]
      end

      private

      def dispatch_record(record, now_ms)
        call = handler_call_for(record)
        apply_handler_result(record, call.result, now_ms, call.error)
      rescue DAG::Effects::StaleLeaseError => error
        DispatchAccumulator.new(
          succeeded: [],
          failed: [],
          released: [],
          errors: [stale_lease_error(record, error)]
        )
      end

      def handler_call_for(record)
        handler = handlers[record.type]
        return unknown_handler_call(record) if handler.nil?

        invoke_handler(record, handler)
      end

      def invoke_handler(record, handler)
        result = handler.call(record)
        return HandlerCall.new(result: result, error: nil) if result.is_a?(DAG::Effects::HandlerResult)

        bad_return_call(record, result)
      rescue => error
        raised_handler_call(record, error)
      end

      def unknown_handler_call(record)
        if unknown_handler_policy == :raise
          raise DAG::Effects::UnknownHandlerError, "no handler registered for effect type: #{record.type}"
        end

        error = unknown_handler_error(record)
        HandlerCall.new(
          result: DAG::Effects::HandlerResult.failed(error: error, retriable: false),
          error: error
        )
      end

      def bad_return_call(record, result)
        error = boundary_error(record, code: :handler_bad_return, class_name: result.class.name)
        HandlerCall.new(
          result: DAG::Effects::HandlerResult.failed(error: error, retriable: true),
          error: error
        )
      end

      def raised_handler_call(record, error)
        payload = boundary_error(
          record,
          code: :handler_raised,
          class_name: error.class.name,
          message: error.message
        )
        HandlerCall.new(
          result: DAG::Effects::HandlerResult.failed(error: payload, retriable: true),
          error: payload
        )
      end

      def apply_handler_result(record, result, now_ms, error)
        updated = if result.success?
          storage.mark_effect_succeeded(
            effect_id: record.id,
            owner_id: owner_id,
            result: result.result,
            external_ref: result.external_ref,
            now_ms: now_ms
          )
        else
          storage.mark_effect_failed(
            effect_id: record.id,
            owner_id: owner_id,
            error: result.error,
            retriable: result.retriable?,
            not_before_ms: result.not_before_ms,
            now_ms: now_ms
          )
        end
        released = release_after_terminal(record, result, now_ms)

        DispatchAccumulator.new(
          succeeded: result.success? ? [updated] : [],
          failed: result.success? ? [] : [updated],
          released: released,
          errors: error.nil? ? [] : [error]
        )
      end

      def release_after_terminal(record, result, now_ms)
        return [] if result.retriable?

        storage.release_nodes_satisfied_by_effect(effect_id: record.id, now_ms: now_ms)
      end

      def unknown_handler_error(record)
        effect_error(record, code: :unknown_handler)
      end

      def boundary_error(record, code:, class_name:, message: nil)
        base = effect_error(record, code: code).merge(class: class_name)
        return base if message.nil?

        base.merge(message: message)
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
