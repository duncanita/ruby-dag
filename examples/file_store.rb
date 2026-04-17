# frozen_string_literal: true

# Durable execution with a file-backed execution store.
#
# Run: ruby -Ilib examples/file_store.rb

require "dag"
require "tmpdir"

fetch_calls = 0
transform_calls = 0

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

Dir.mktmpdir("dag-file-store-example") do |dir|
  first_store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
  second_store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)

  puts "=== First Run (file store) ==="
  first = DAG::Workflow::Runner.new(build_definition.call,
    parallel: false,
    execution_store: first_store,
    workflow_id: "example-file-store").call
  puts "Status: #{first.status}"
  puts "Outputs: #{first.outputs.transform_values(&:value)}"
  puts

  puts "=== Second Run (fresh store instance) ==="
  second = DAG::Workflow::Runner.new(build_definition.call,
    parallel: false,
    execution_store: second_store,
    workflow_id: "example-file-store").call
  puts "Status: #{second.status}"
  puts "Outputs: #{second.outputs.transform_values(&:value)}"
  puts

  history = second_store.load_output(workflow_id: "example-file-store", node_path: [:fetch], version: :all)

  puts "Fetch calls: #{fetch_calls}"
  puts "Transform calls: #{transform_calls}"
  puts "Stored workflow status: #{second_store.load_run("example-file-store")[:workflow_status]}"
  puts "Stored versions: #{history.map { |entry| entry[:version] }.inspect}"
end
