# frozen_string_literal: true

module DAG
  # Immutable coordinate for a workflow revision. Runner, storage, and
  # diagnostics use this pair as the current plan-version boundary.
  # @api public
  PlanVersion = Data.define(:workflow_id, :revision) do
    class << self
      remove_method :[]

      # @param workflow_id [String]
      # @param revision [Integer]
      # @return [PlanVersion]
      def [](workflow_id:, revision:)
        new(workflow_id: workflow_id, revision: revision)
      end
    end

    def initialize(workflow_id:, revision:)
      DAG::Validation.nonempty_string!(workflow_id, "workflow_id")
      DAG::Validation.revision!(revision)

      frozen_workflow_id = DAG.frozen_copy(workflow_id)

      super(workflow_id: frozen_workflow_id, revision: revision)
    end
  end
end
