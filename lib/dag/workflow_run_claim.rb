# frozen_string_literal: true

module DAG
  # Immutable workflow execution lease with a monotonic fencing token.
  # @api public
  WorkflowRunClaim = Data.define(:workflow_id, :owner_id, :fencing_token, :lease_until_ms) do
    def initialize(workflow_id:, owner_id:, fencing_token:, lease_until_ms:)
      DAG::Validation.string!(workflow_id, "workflow_id")
      DAG::Validation.string!(owner_id, "owner_id")
      DAG::Validation.positive_integer!(fencing_token, "fencing_token")
      DAG::Validation.integer!(lease_until_ms, "lease_until_ms")
      super(
        workflow_id: DAG.frozen_copy(workflow_id),
        owner_id: DAG.frozen_copy(owner_id),
        fencing_token: fencing_token,
        lease_until_ms: lease_until_ms
      )
    end
  end
end
