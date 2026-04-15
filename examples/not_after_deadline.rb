# frozen_string_literal: true

# not_after scheduling: the runner fails deterministically when a step is already
# past its latest allowed start/completion window before the invocation reaches it.
#
# Run: ruby -Ilib examples/not_after_deadline.rb

require "dag"

clock = Struct.new(:wall_time, :mono_time) do
  def wall_now = wall_time
  def monotonic_now = mono_time
end.new(Time.utc(2026, 4, 15, 10, 0, 1), 0.0)

store = DAG::Workflow::ExecutionStore::MemoryStore.new
calls = 0
workflow = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :ruby,
    resume_key: "fetch-v1",
    callable: ->(_input) { DAG::Success.new(value: "payload") }
  },
  scheduled: {
    type: :ruby,
    depends_on: [:fetch],
    resume_key: "scheduled-v1",
    schedule: {not_after: Time.utc(2026, 4, 15, 10, 0, 0)},
    callable: ->(_input) do
      calls += 1
      DAG::Success.new(value: "too-late")
    end
  }
)

result = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  clock: clock,
  workflow_id: "example-not-after",
  execution_store: store).call

puts "=== Run (expired) ==="
puts "Status: #{result.status}"
puts "Failed node: #{result.error[:failed_node]}"
puts "Error code: #{result.error.dig(:step_error, :code)}"
puts "Outputs so far: #{result.outputs.transform_values(&:value)}"
puts "Scheduled calls: #{calls}"
