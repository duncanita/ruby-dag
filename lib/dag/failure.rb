# frozen_string_literal: true

module DAG
  # Step result indicating the step failed. `error` is a JSON-safe value
  # describing the failure; `retriable: true` lets the Runner retry the
  # node within the per-node attempt budget.
  #
  # Retry timing is deliberately immediate: a retriable Failure makes the
  # node `:pending` again and the Runner re-executes it in the same
  # `#call`, so the attempt budget can be consumed back-to-back. There is
  # no backoff field here by design — a step that wants to retry *later*
  # must return `Waiting` (optionally with `not_before_ms` and a blocking
  # effect) so the delay is owned by the scheduler/dispatcher boundary,
  # not by the kernel's failure semantics.
  # @api public
  Failure = Data.define(:error, :retriable, :metadata) do
    include Result

    class << self
      remove_method :[]

      # @param error [Object] JSON-safe error payload (typically `{code:, ...}`)
      # @param retriable [Boolean]
      # @param metadata [Hash] JSON-safe
      # @return [Failure]
      def [](error:, retriable: false, metadata: {})
        new(error: error, retriable: retriable, metadata: metadata)
      end
    end

    def initialize(error:, retriable: false, metadata: {})
      DAG.json_safe!(error, "$root.error")
      DAG.json_safe!(metadata, "$root.metadata")

      super(
        error: DAG.frozen_copy(error),
        retriable: !!retriable,
        metadata: DAG.frozen_copy(metadata)
      )
    end

    # @return [false]
    def success? = false

    # @return [true]
    def failure? = true

    # @return [nil]
    def value = nil

    # No-op on failure.
    # @return [Failure] self
    def and_then = self

    # No-op on failure.
    # @return [Failure] self
    def map = self

    # Failure-side counterpart of and_then. Block must return a Result, which
    # lets you turn a failure back into a success (or into a different failure):
    #
    #   parse_config(path)
    #     .recover { |_| Success.new(value: DEFAULT_CONFIG) }
    # @yieldparam error [Object]
    # @return [DAG::Result]
    def recover
      Result.assert_result!(yield(error), "recover")
    end

    # @raise [RuntimeError]
    def unwrap! = raise("Unwrap called on Failure: #{error}")

    # Full-fidelity JSON-safe projection; round-trips via {Result.from_h}.
    # `retriable` is load-bearing for retry semantics and must survive
    # persistence.
    # @return [Hash]
    def to_h = {status: :failure, error: error, retriable: retriable, metadata: metadata}

    # Rebuild a Failure from a {#to_h} projection (Symbol or String keys).
    # @param hash [Hash]
    # @return [Failure]
    def self.from_h(hash)
      DAG::Validation.hash!(hash, "failure hash")
      new(
        error: DAG::Snapshot.fetch(hash, :error),
        retriable: DAG::Snapshot.fetch(hash, :retriable, false),
        metadata: DAG::Snapshot.fetch(hash, :metadata, {})
      )
    end

    # @return [String]
    def inspect = "Failure(#{error.inspect})"
    alias_method :to_s, :inspect
  end
end
