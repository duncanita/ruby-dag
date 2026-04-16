# frozen_string_literal: true

# Invalidation cascade: mark completed reusable outputs stale, then let the next
# run recompute that branch from the current definition.
#
# Run: ruby -Ilib examples/invalidation_cascade.rb

require "dag"

store = DAG::Workflow::ExecutionStore::MemoryStore.new
source_calls = 0
transform_calls = 0

workflow = DAG::Workflow::Loader.from_hash(
  source: {
    type: :ruby,
    resume_key: "source-v1",
    callable: ->(_input) do
      source_calls += 1
      DAG::Success.new(value: "source-#{source_calls}")
    end
  },
  transform: {
    type: :ruby,
    depends_on: [:source],
    resume_key: "transform-v1",
    callable: ->(input) do
      transform_calls += 1
      DAG::Success.new(value: "#{input[:source]}:transform-#{transform_calls}")
    end
  }
)

first = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  workflow_id: "example-invalidation",
  execution_store: store).call

invalidated = DAG::Workflow.invalidate(
  workflow_id: "example-invalidation",
  node: [:source],
  definition: workflow,
  execution_store: store,
  cause: DAG::Workflow.upstream_change_cause(source: :coordinator)
)

second = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  workflow_id: "example-invalidation",
  execution_store: store).call

stale_node = store.load_node(workflow_id: "example-invalidation", node_path: [:source])

puts "=== First Run ==="
puts "Source: #{first.outputs[:source].value}"
puts "Transform: #{first.outputs[:transform].value}"
puts "=== Invalidate source ==="
puts "Stale nodes: #{invalidated.inspect}"
puts "Stale cause code: #{stale_node[:stale_cause][:code]}"
puts "Stale cause source: #{stale_node[:stale_cause][:source]}"
puts "=== Second Run (recompute stale nodes) ==="
puts "Source: #{second.outputs[:source].value}"
puts "Transform: #{second.outputs[:transform].value}"
puts "Source calls: #{source_calls}"
puts "Transform calls: #{transform_calls}"
