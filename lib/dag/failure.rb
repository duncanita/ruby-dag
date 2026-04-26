# frozen_string_literal: true

module DAG
  Failure = Data.define(:error, :retriable, :metadata) do
    include Result

    class << self
      remove_method :[]

      def [](error:, retriable: false, metadata: {})
        new(error: error, retriable: retriable, metadata: metadata)
      end
    end

    def initialize(error:, retriable: false, metadata: {})
      DAG.json_safe!(error, "$root.error")
      DAG.json_safe!(metadata, "$root.metadata")

      super(
        error: DAG.deep_freeze(DAG.deep_dup(error)),
        retriable: !!retriable,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end

    def success? = false
    def failure? = true
    def value = nil

    def and_then = self
    def map = self

    # Failure-side counterpart of and_then. Block must return a Result, which
    # lets you turn a failure back into a success (or into a different failure):
    #
    #   parse_config(path)
    #     .recover { |_| Success.new(value: DEFAULT_CONFIG) }
    def recover
      Result.assert_result!(yield(error), "recover")
    end

    def unwrap! = raise("Unwrap called on Failure: #{error}")
    def to_h = {status: :failure, error: error}
    def inspect = "Failure(#{error.inspect})"
    alias_method :to_s, :inspect
  end
end
