# frozen_string_literal: true

# Dynamic graph mutation impact: inspect which persisted nodes become obsolete or
# stale before applying a subtree replacement transition.
#
# Run: ruby -Ilib examples/subtree_replacement_impact.rb

require "dag"

store = DAG::Workflow::ExecutionStore::MemoryStore.new
workflow = DAG::Workflow::Loader.from_hash(
  source: {
    type: :ruby,
    callable: ->(_input) { DAG::Success.new(value: "payload") }
  },
  process: {
    type: :ruby,
    depends_on: [:source],
    callable: ->(input) { DAG::Success.new(value: input[:source].upcase) }
  },
  report: {
    type: :ruby,
    depends_on: [:process],
    callable: ->(input) { DAG::Success.new(value: "report:#{input[:process]}") }
  },
  notify: {
    type: :ruby,
    depends_on: [:report],
    callable: ->(input) { DAG::Success.new(value: "notify:#{input[:report]}") }
  }
)

store.begin_run(
  workflow_id: "example-subtree-impact",
  definition_fingerprint: "fp-1",
  node_paths: [[:source], [:process], [:report], [:notify]]
)
store.set_node_state(workflow_id: "example-subtree-impact", node_path: [:source], state: :completed)
store.set_node_state(workflow_id: "example-subtree-impact", node_path: [:process], state: :completed)
store.set_node_state(workflow_id: "example-subtree-impact", node_path: [:report], state: :completed)
store.set_node_state(workflow_id: "example-subtree-impact", node_path: [:notify], state: :waiting)
store.save_output(
  workflow_id: "example-subtree-impact",
  node_path: [:process],
  version: 1,
  result: DAG::Success.new(value: "PAYLOAD"),
  reusable: true,
  superseded: false
)
store.save_output(
  workflow_id: "example-subtree-impact",
  node_path: [:report],
  version: 1,
  result: DAG::Success.new(value: "report:PAYLOAD"),
  reusable: true,
  superseded: false
)

impact = DAG::Workflow.subtree_replacement_impact(
  workflow_id: "example-subtree-impact",
  definition: workflow,
  root_node: :process,
  execution_store: store
)

DAG::Workflow.apply_subtree_replacement_impact(
  workflow_id: "example-subtree-impact",
  definition: workflow,
  root_node: :process,
  execution_store: store,
  cause: {source: :planner}
)

process_node = store.load_node(workflow_id: "example-subtree-impact", node_path: [:process])
report_node = store.load_node(workflow_id: "example-subtree-impact", node_path: [:report])

running_store = DAG::Workflow::ExecutionStore::MemoryStore.new
running_store.begin_run(
  workflow_id: "example-subtree-impact-running",
  definition_fingerprint: "fp-1",
  node_paths: [[:process], [:report]]
)
running_store.set_node_state(workflow_id: "example-subtree-impact-running", node_path: [:process], state: :running)

running_root_error = begin
  DAG::Workflow.subtree_replacement_impact(
    workflow_id: "example-subtree-impact-running",
    definition: workflow,
    root_node: :process,
    execution_store: running_store
  )
  "no error"
rescue ArgumentError => e
  e.message
end

puts "=== Planned Impact ==="
puts "Obsolete nodes: #{impact[:obsolete_nodes].inspect}"
puts "Stale nodes: #{impact[:stale_nodes].inspect}"
puts "=== Applied Impact ==="
puts "Process state: #{process_node[:state]}"
puts "Report state: #{report_node[:state]}"
puts "Report stale cause code: #{report_node[:stale_cause][:code]}"
puts "Report stale cause source: #{report_node[:stale_cause][:source]}"
puts "Running-root guard: #{running_root_error}"
