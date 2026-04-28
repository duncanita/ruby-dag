# frozen_string_literal: true

module DAG
  # Step result indicating success. `value` is the JSON-safe step output;
  # `context_patch` is merged into the downstream execution context;
  # `proposed_mutations` (when non-empty) drives the workflow to `:paused`
  # so a mutation service can apply structural changes.
  # @api public
  Success = Data.define(:value, :context_patch, :proposed_mutations, :metadata) do
    include Result

    class << self
      remove_method :[]

      # @param value [Object] JSON-safe value
      # @param context_patch [Hash] JSON-safe patch merged into context
      # @param proposed_mutations [Array<DAG::ProposedMutation>]
      # @param metadata [Hash] JSON-safe
      # @return [Success]
      def [](value: nil, context_patch: {}, proposed_mutations: [], metadata: {})
        new(
          value: value,
          context_patch: context_patch,
          proposed_mutations: proposed_mutations,
          metadata: metadata
        )
      end
    end

    def initialize(value: nil, context_patch: {}, proposed_mutations: [], metadata: {})
      DAG.json_safe!(value, "$root.value")
      DAG.json_safe!(context_patch, "$root.context_patch")
      DAG.json_safe!(metadata, "$root.metadata")
      validate_proposed_mutations!(proposed_mutations)

      super(
        value: DAG.deep_freeze(DAG.deep_dup(value)),
        context_patch: DAG.deep_freeze(DAG.deep_dup(context_patch)),
        proposed_mutations: DAG.deep_freeze(proposed_mutations.dup),
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end

    # @return [true]
    def success? = true

    # @return [false]
    def failure? = false

    # @return [nil]
    def error = nil

    # Pass `value` to `block`; the block must return a {DAG::Result}.
    # @yieldparam value [Object]
    # @return [DAG::Result]
    def and_then
      Result.assert_result!(yield(value), "and_then")
    end

    # Build a new Success with `value` replaced by the block's return.
    # @return [Success]
    def map
      Success.new(
        value: yield(value),
        context_patch: context_patch,
        proposed_mutations: proposed_mutations,
        metadata: metadata
      )
    end

    # No-op on success.
    # @return [Success] self
    def recover = self

    # @return [Object] `value`
    def unwrap! = value

    # @return [Hash] {status: :success, value:}
    def to_h = {status: :success, value: value}

    # @return [String]
    def inspect = "Success(#{value.inspect})"
    alias_method :to_s, :inspect

    private

    def validate_proposed_mutations!(proposed_mutations)
      unless proposed_mutations.is_a?(Array)
        raise ArgumentError, "proposed_mutations must be an Array"
      end

      proposed_mutations.each do |mutation|
        unless mutation.is_a?(DAG::ProposedMutation)
          raise ArgumentError, "proposed_mutations must contain ProposedMutation"
        end
      end
    end
  end
end
