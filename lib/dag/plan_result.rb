# frozen_string_literal: true

module DAG
  # Result of `DefinitionEditor#plan`. Either a valid plan with a
  # `new_definition` and the set of invalidated node ids, or an invalid
  # plan with a human-readable `reason`.
  # @api public
  PlanResult = Data.define(:valid, :new_definition, :invalidated_node_ids, :reason) do
    class << self
      remove_method :[]

      # Build a valid PlanResult.
      # @param new_definition [DAG::Workflow::Definition]
      # @param invalidated_node_ids [Array<Symbol>]
      # @return [PlanResult]
      def valid(new_definition:, invalidated_node_ids:)
        new(valid: true, new_definition: new_definition, invalidated_node_ids: invalidated_node_ids, reason: nil)
      end

      # Build an invalid PlanResult.
      # @param reason [String]
      # @return [PlanResult]
      def invalid(reason)
        new(valid: false, new_definition: nil, invalidated_node_ids: [], reason: reason)
      end
    end

    def initialize(valid:, new_definition:, invalidated_node_ids:, reason:)
      super(
        valid: valid,
        new_definition: new_definition,
        invalidated_node_ids: DAG.deep_freeze(invalidated_node_ids.map(&:to_sym).sort_by(&:to_s)),
        reason: reason
      )
    end

    def valid? = valid
  end
end
