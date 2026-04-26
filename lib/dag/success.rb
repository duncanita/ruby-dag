# frozen_string_literal: true

module DAG
  Success = Data.define(:value, :context_patch, :proposed_mutations, :metadata) do
    include Result

    class << self
      remove_method :[]

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

    def success? = true
    def failure? = false
    def error = nil

    def and_then
      Result.assert_result!(yield(value), "and_then")
    end

    def map
      Success.new(
        value: yield(value),
        context_patch: context_patch,
        proposed_mutations: proposed_mutations,
        metadata: metadata
      )
    end

    def recover = self

    def unwrap! = value
    def to_h = {status: :success, value: value}
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
