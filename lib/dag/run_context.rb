# frozen_string_literal: true

module DAG
  # Per-call constants threaded through Runner internals: the workflow id and
  # revision being executed, the definition, the runtime profile, the
  # initial_context (loaded once), and a predecessors_by_node map so the
  # eligibility loop and effective-context calculation never re-walk the
  # graph or re-load the workflow row.
  RunContext = Data.define(:workflow_id, :revision, :definition, :runtime_profile, :initial_context, :predecessors_by_node)
end
