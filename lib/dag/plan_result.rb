# frozen_string_literal: true

module DAG
  # Result of `DefinitionEditor#plan`. Either a valid plan with a
  # `new_definition` and the set of invalidated node ids, or an invalid
  # plan with a human-readable `reason` and optional stable `code`.
  # @api public
  PlanResult = Data.define(:valid, :new_definition, :invalidated_node_ids, :reason, :code) do
    class << self
      remove_method :[]

      # Build a valid PlanResult.
      # @param new_definition [DAG::Workflow::Definition]
      # @param invalidated_node_ids [Array<Symbol>]
      # @return [PlanResult]
      def valid(new_definition:, invalidated_node_ids:)
        new(valid: true, new_definition: new_definition, invalidated_node_ids: invalidated_node_ids, reason: nil, code: nil)
      end

      # Build an invalid PlanResult.
      # @param reason [String]
      # @param code [Symbol, nil] stable cause; nil for legacy callers
      # @return [PlanResult]
      def invalid(reason, code: nil)
        new(valid: false, new_definition: nil, invalidated_node_ids: [], reason: reason, code: code)
      end
    end

    def initialize(valid:, new_definition:, invalidated_node_ids:, reason:, code: nil)
      DAG::Validation.member!(code, DAG::PlanResult::CODES, "code") unless code.nil?
      raise ArgumentError, "valid plan cannot have rejection code" if valid && code

      super(
        valid: valid,
        new_definition: new_definition,
        invalidated_node_ids: DAG.deep_freeze(invalidated_node_ids.map(&:to_sym).sort_by(&:to_s)),
        reason: reason,
        code: code
      )
    end

    def valid? = valid
  end

  # Closed vocabulary for editor rejection causes.
  PlanResult::CODES = %i[unknown_target node_id_collision would_create_cycle unsupported_mutation invalid_replacement].freeze
end
