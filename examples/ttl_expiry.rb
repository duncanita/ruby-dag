# frozen_string_literal: true

# schedule.ttl: reusable outputs expire relative to the injected wall clock,
# causing the runner to execute the step again instead of reusing stale output.
#
# Run: ruby -Ilib examples/ttl_expiry.rb

require "dag"

class ExampleClock
  ClockState = Data.define(:wall_time, :mono_time)

  def initialize(wall_time:, mono_time:)
    @state = ClockState.new(wall_time: wall_time, mono_time: mono_time)
  end

  def wall_now = @state.wall_time
  def monotonic_now = @state.mono_time

  def advance(seconds)
    @state = @state.with(wall_time: @state.wall_time + seconds)
  end
end

clock = ExampleClock.new(wall_time: Time.utc(2026, 4, 15, 9, 0, 0), mono_time: 0.0)
store = DAG::Workflow::ExecutionStore::MemoryStore.new
calls = 0
workflow = DAG::Workflow::Loader.from_hash(
  cached: {
    type: :ruby,
    resume_key: "cached-v1",
    schedule: {ttl: 300},
    callable: ->(_input) do
      calls += 1
      DAG::Success.new(value: "run-#{calls}")
    end
  }
)

first = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  clock: clock,
  workflow_id: "example-ttl",
  execution_store: store).call

clock.advance(120)
second = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  clock: clock,
  workflow_id: "example-ttl",
  execution_store: store).call

clock.advance(240)
third = DAG::Workflow::Runner.new(workflow,
  parallel: false,
  clock: clock,
  workflow_id: "example-ttl",
  execution_store: store).call

node = store.load_node(workflow_id: "example-ttl", node_path: [:cached])

puts "=== First Run ==="
puts "Output: #{first.outputs[:cached].value}"
puts "=== Second Run (reuse within ttl) ==="
puts "Output: #{second.outputs[:cached].value}"
puts "=== Third Run (ttl expired) ==="
puts "Output: #{third.outputs[:cached].value}"
puts "Calls: #{calls}"
puts "Stale cause: #{node[:stale_cause][:code]}"
