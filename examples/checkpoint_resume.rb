# frozen_string_literal: true

# Durable execution: persist successful outputs and reuse them on resume.
#
# Run: ruby -Ilib examples/checkpoint_resume.rb

require "dag"

fetch_calls = 0
transform_calls = 0

store = DAG::Workflow::ExecutionStore::MemoryStore.new

build_definition = lambda do
  DAG::Workflow::Loader.from_hash(
    fetch: {
      type: :ruby,
      resume_key: "fetch-v1",
      callable: ->(_input) do
        fetch_calls += 1
        DAG::Success.new(value: "payload-#{fetch_calls}")
      end
    },
    transform: {
      type: :ruby,
      depends_on: [:fetch],
      resume_key: "transform-v1",
      callable: ->(input) do
        transform_calls += 1
        DAG::Success.new(value: input[:fetch].upcase)
      end
    }
  )
end

runner = lambda do
  DAG::Workflow::Runner.new(build_definition.call,
    parallel: false,
    execution_store: store,
    workflow_id: "example-resume")
end

puts "=== First Run ==="
first = runner.call.call
puts "Status: #{first.status}"
puts "Outputs: #{first.outputs.transform_values(&:value)}"
puts "Trace attempts: #{first.trace.size}"
puts

puts "=== Second Run (resume) ==="
second = runner.call.call
puts "Status: #{second.status}"
puts "Outputs: #{second.outputs.transform_values(&:value)}"
puts "Trace attempts: #{second.trace.size}"
puts

puts "Fetch calls: #{fetch_calls}"
puts "Transform calls: #{transform_calls}"
puts "Stored workflow status: #{store.load_run("example-resume")[:workflow_status]}"
puts "Reusable fetch output: #{store.load_output(workflow_id: "example-resume", node_path: [:fetch])[:result].value}"
