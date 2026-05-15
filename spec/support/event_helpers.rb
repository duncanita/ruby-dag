# frozen_string_literal: true

module EventHelpers
  def build_event(type = :node_started, workflow_id: "x", revision: 1, at_ms: 0, node_id: nil, attempt_id: nil, payload: {})
    DAG::Event[
      type: type,
      workflow_id: workflow_id,
      revision: revision,
      at_ms: at_ms,
      node_id: node_id,
      attempt_id: attempt_id,
      payload: payload
    ]
  end
end
