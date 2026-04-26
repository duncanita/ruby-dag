# frozen_string_literal: true

module DAG
  PlanResult = Data.define(:valid, :new_definition, :invalidated_node_ids, :reason) do
    class << self
      remove_method :[]

      def valid(new_definition:, invalidated_node_ids:)
        new(valid: true, new_definition: new_definition, invalidated_node_ids: invalidated_node_ids, reason: nil)
      end

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
