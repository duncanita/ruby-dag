# frozen_string_literal: true

module DAG
  module Effects
    # Result returned by an effect handler. It is deliberately smaller than a
    # Record: storage owns leases, ids, and timestamps.
    # @api public
    HandlerResult = Data.define(:status, :result, :error, :external_ref, :not_before_ms, :metadata) do
      class << self
        remove_method :[]

        # @return [HandlerResult]
        def [](status:, result: nil, error: nil, external_ref: nil, not_before_ms: nil, metadata: {})
          new(
            status: status,
            result: result,
            error: error,
            external_ref: external_ref,
            not_before_ms: not_before_ms,
            metadata: metadata
          )
        end

        # @param result [Object] JSON-safe durable effect result
        # @param external_ref [Object, nil] JSON-safe external system ref
        # @param metadata [Hash] JSON-safe
        # @return [HandlerResult]
        def succeeded(result:, external_ref: nil, metadata: {})
          new(status: :succeeded, result: result, external_ref: external_ref, metadata: metadata)
        end

        # @param error [Object] JSON-safe durable error
        # @param retriable [Boolean]
        # @param not_before_ms [Integer, nil]
        # @param metadata [Hash] JSON-safe
        # @return [HandlerResult]
        def failed(error:, retriable:, not_before_ms: nil, metadata: {})
          DAG::Validation.boolean!(retriable, "retriable")

          new(
            status: retriable ? :failed_retriable : :failed_terminal,
            error: error,
            not_before_ms: not_before_ms,
            metadata: metadata
          )
        end
      end

      def initialize(status:, result: nil, error: nil, external_ref: nil, not_before_ms: nil, metadata: {})
        unless DAG::Effects::HandlerResult::STATUSES.include?(status)
          raise ArgumentError, "invalid handler result status: #{status.inspect}"
        end
        DAG::Validation.optional_integer!(not_before_ms, "not_before_ms")
        raise ArgumentError, "succeeded does not accept error" if status == :succeeded && !error.nil?
        raise ArgumentError, "#{status} does not accept result" if status != :succeeded && !result.nil?
        DAG.json_safe!(result, "$root.result")
        DAG.json_safe!(error, "$root.error")
        DAG.json_safe!(external_ref, "$root.external_ref")
        DAG.json_safe!(metadata, "$root.metadata")

        super(
          status: status,
          result: DAG.frozen_copy(result),
          error: DAG.frozen_copy(error),
          external_ref: DAG.frozen_copy(external_ref),
          not_before_ms: not_before_ms,
          metadata: DAG.frozen_copy(metadata)
        )
      end

      # @return [Boolean]
      def success? = status == :succeeded

      # @return [Boolean]
      def failure? = !success?

      # @return [Boolean]
      def retriable? = status == :failed_retriable
    end

    # Closed status set for handler results.
    HandlerResult::STATUSES = %i[succeeded failed_retriable failed_terminal].freeze
  end
end
