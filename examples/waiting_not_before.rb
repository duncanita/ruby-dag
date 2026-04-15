# frozen_string_literal: true

# Waiting/not_before scheduling: the runner does not sleep. It returns a
# waiting RunResult until the injected clock reaches the node's not_before time.
#
# Run: ruby -Ilib examples/waiting_not_before.rb

require "dag"

clock = Struct.new(:wall_time, :mono_time) do
  def wall_now = wall_time
  def monotonic_now = mono_time
  def advance(seconds) = self.wall_time += seconds
end.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)

store = DAG::Workflow::ExecutionStore::MemoryStore.new
workflow = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :ruby,
    resume_key: "fetch-v1",
    callable: ->(_input) { DAG::Success.new(value: "ready") }
  },
  scheduled: {
    type: :ruby,
    depends_on: [:fetch],
    resume_key: "scheduled-v1",
    schedule: {not_before: Time.utc(2026, 4, 15, 10, 0, 0)},
    callable: ->(input) { DAG::Success.new(value: input[:fetch].upcase) }
  }
)

first = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  clock: clock,
  workflow_id: "example-waiting",
  execution_store: store).call

puts "=== First Run (waiting) ==="
puts "Status: #{first.status}"
puts "Waiting nodes: #{first.waiting_nodes.inspect}"
puts "Outputs so far: #{first.outputs.transform_values(&:value)}"
puts

clock.advance(3600)

second = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  clock: clock,
  workflow_id: "example-waiting",
  execution_store: store).call

puts "=== Second Run (ready) ==="
puts "Status: #{second.status}"
puts "Outputs: #{second.outputs.transform_values(&:value)}"
