# frozen_string_literal: true

# Nested invalidation cascade: invalidate a node inside a sub-workflow using its
# full node_path, then rerun only that nested branch on the next invocation.
#
# Run: ruby -Ilib examples/nested_invalidation_cascade.rb

require "dag"

store = DAG::Workflow::ExecutionStore::MemoryStore.new
transform_calls = 0
publish_calls = 0

child = DAG::Workflow::Loader.from_hash(
  transform: {
    type: :ruby,
    resume_key: "transform-v1",
    callable: ->(_input) do
      transform_calls += 1
      DAG::Success.new(value: "transform-#{transform_calls}")
    end
  },
  publish: {
    type: :ruby,
    depends_on: [:transform],
    resume_key: "publish-v1",
    callable: ->(input) do
      publish_calls += 1
      DAG::Success.new(value: "#{input[:transform]}:publish-#{publish_calls}")
    end
  }
)

parent = DAG::Workflow::Loader.from_hash(
  process: {
    type: :sub_workflow,
    definition: child,
    resume_key: "process-v1",
    output_key: :publish
  }
)

first = DAG::Workflow::Runner.new(parent,
  parallel: false,
  workflow_id: "example-nested-invalidation",
  execution_store: store).call

invalidated = DAG::Workflow.invalidate(
  workflow_id: "example-nested-invalidation",
  node: [:process, :transform],
  definition: parent,
  execution_store: store
)

second = DAG::Workflow::Runner.new(parent,
  parallel: false,
  workflow_id: "example-nested-invalidation",
  execution_store: store).call

puts "=== First Run ==="
puts "Process output: #{first.outputs[:process].value}"
puts "=== Invalidate nested node ==="
puts "Invalidated nodes: #{invalidated.sort_by { |path| path.map(&:to_s) }.inspect}"
puts "=== Second Run ==="
puts "Process output: #{second.outputs[:process].value}"
puts "Transform calls: #{transform_calls}"
puts "Publish calls: #{publish_calls}"
