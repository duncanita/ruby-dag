# frozen_string_literal: true

module DAG
  ApplyResult = Data.define(:workflow_id, :revision, :definition, :invalidated_node_ids, :event)
end
