# frozen_string_literal: true

# Pause/resume is coordinator-driven: set a durable pause flag in the execution
# store, let the runner stop cleanly between layers, then clear the flag and run
# the same workflow_id again.
#
# Run: ruby -Ilib examples/pause_resume.rb

require "dag"

store = DAG::Workflow::ExecutionStore::MemoryStore.new
fetch_calls = 0
transform_calls = 0

workflow = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :ruby,
    resume_key: "fetch-v1",
    callable: ->(_input) do
      fetch_calls += 1
      DAG::Success.new(value: "payload")
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

first = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  workflow_id: "example-pause-resume",
  execution_store: store,
  on_step_finish: lambda do |name, _result|
    store.set_pause_flag(workflow_id: "example-pause-resume", paused: true) if name == :fetch
  end).call

puts "=== First Run (pause requested) ==="
puts "Status: #{first.status}"
puts "Outputs so far: #{first.outputs.transform_values(&:value)}"
puts "Stored workflow status: #{store.load_run("example-pause-resume")[:workflow_status]}"
puts

store.set_pause_flag(workflow_id: "example-pause-resume", paused: false)

second = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  workflow_id: "example-pause-resume",
  execution_store: store).call

puts "=== Second Run (resume) ==="
puts "Status: #{second.status}"
puts "Outputs: #{second.outputs.transform_values(&:value)}"
puts "Fetch calls: #{fetch_calls}"
puts "Transform calls: #{transform_calls}"
