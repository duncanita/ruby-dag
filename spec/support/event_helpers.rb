# frozen_string_literal: true

module EventHelpers
  def build_event(type = :node_started, workflow_id: "x", revision: 1, at_ms: 0, payload: {})
    DAG::Event[
      type: type,
      workflow_id: workflow_id,
      revision: revision,
      at_ms: at_ms,
      payload: payload
    ]
  end
end
