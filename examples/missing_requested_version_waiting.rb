# frozen_string_literal: true

# Missing requested version semantics:
# - local missing historical version fails explicitly
# - cross-workflow missing version waits if a resolver may satisfy it later
#
# Run: ruby -Ilib examples/missing_requested_version_waiting.rb

require "dag"

store = DAG::Workflow::ExecutionStore::MemoryStore.new
resolver_calls = 0
resolver = lambda do |workflow_id, node_name, version|
  resolver_calls += 1
  next nil if resolver_calls == 1

  store.load_output(workflow_id: workflow_id, node_path: [node_name], version: version)
end

waiting_workflow = DAG::Workflow::Loader.from_hash(
  consumer: {
    type: :ruby,
    depends_on: [{workflow: "pipeline-a", node: :validated_output, version: 2, as: :validated}],
    resume_key: "consumer-v1",
    callable: ->(input) { DAG::Success.new(value: input[:validated]) }
  }
)

first = DAG::Workflow::Runner.new(waiting_workflow,
  parallel: false,
  cross_workflow_resolver: resolver,
  execution_store: store,
  workflow_id: "example-missing-version").call

store.begin_run(workflow_id: "pipeline-a", definition_fingerprint: "fp-external", node_paths: [[:validated_output]])
store.save_output(
  workflow_id: "pipeline-a",
  node_path: [:validated_output],
  version: 2,
  result: DAG::Success.new(value: "external-v2"),
  reusable: true,
  superseded: false
)

second = DAG::Workflow::Runner.new(waiting_workflow,
  parallel: false,
  cross_workflow_resolver: resolver,
  execution_store: store,
  workflow_id: "example-missing-version").call

local_failure_workflow = DAG::Workflow::Loader.from_hash(
  source: {
    type: :ruby,
    resume_key: "source-v1",
    callable: ->(_input) { DAG::Success.new(value: "scan-1") }
  },
  consumer: {
    type: :ruby,
    depends_on: [{from: :source, version: 2, as: :missing_version}],
    resume_key: "consumer-v2",
    callable: ->(input) { DAG::Success.new(value: input[:missing_version]) }
  }
)

third = DAG::Workflow::Runner.new(local_failure_workflow,
  parallel: false,
  execution_store: store,
  workflow_id: "example-local-missing-version").call

puts "=== Cross-Workflow First Run ==="
puts "Status: #{first.status}"
puts "Waiting nodes: #{first.waiting_nodes.inspect}"
puts
puts "=== Cross-Workflow Second Run ==="
puts "Status: #{second.status}"
puts "Output: #{second.outputs[:consumer].value}"
puts
puts "=== Local Historical Version ==="
puts "Status: #{third.status}"
puts "Error code: #{third.error[:step_error][:code]}"
