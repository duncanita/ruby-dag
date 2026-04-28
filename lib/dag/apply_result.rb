# frozen_string_literal: true

module DAG
  # Result of `MutationService#apply`. Frozen `Data` carrying the new
  # revision number, the resulting `Definition`, the node ids invalidated
  # by the mutation, and the durable `mutation_applied` event.
  # @api public
  ApplyResult = Data.define(:workflow_id, :revision, :definition, :invalidated_node_ids, :event)
end
