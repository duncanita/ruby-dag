# frozen_string_literal: true

# Versioned dependency inputs: use depends_on metadata to request the latest,
# a specific historical version, or the full version history.
#
# Run: ruby -Ilib examples/versioned_dependency_inputs.rb

require "dag"

class ExampleClock
  ClockState = Data.define(:wall_time, :mono_time)

  def initialize(wall_time:, mono_time:)
    @state = ClockState.new(wall_time: wall_time, mono_time: mono_time)
  end

  def wall_now = @state.wall_time
  def monotonic_now = @state.mono_time

  def advance(seconds)
    @state = @state.with(
      wall_time: @state.wall_time + seconds,
      mono_time: @state.mono_time + seconds
    )
  end
end

clock = ExampleClock.new(wall_time: Time.utc(2026, 4, 15, 9, 0, 0), mono_time: 0.0)
store = DAG::Workflow::ExecutionStore::MemoryStore.new
source_calls = 0

workflow = DAG::Workflow::Loader.from_hash(
  source: {
    type: :ruby,
    resume_key: "source-v1",
    schedule: {ttl: 1},
    callable: ->(_input) do
      source_calls += 1
      DAG::Success.new(value: "scan-#{source_calls}")
    end
  },
  latest_value: {
    type: :ruby,
    depends_on: [{from: :source, as: :latest_value}],
    schedule: {ttl: 1},
    resume_key: "latest-value-v1",
    callable: ->(input) { DAG::Success.new(value: input[:latest_value]) }
  },
  first_value: {
    type: :ruby,
    depends_on: [{from: :source, version: 1, as: :first_value}],
    schedule: {ttl: 1},
    resume_key: "first-value-v1",
    callable: ->(input) { DAG::Success.new(value: input[:first_value]) }
  },
  history: {
    type: :ruby,
    depends_on: [{from: :source, version: :all, as: :history}],
    schedule: {ttl: 1},
    resume_key: "history-v1",
    callable: ->(input) { DAG::Success.new(value: input[:history]) }
  }
)

runner = lambda do
  DAG::Workflow::Runner.new(workflow,
    parallel: false,
    clock: clock,
    workflow_id: "example-versioned-inputs",
    execution_store: store)
end

puts "=== First Run ==="
first = runner.call.call
puts "Source: #{first.outputs[:source].value}"
puts

clock.advance(2)

puts "=== Second Run ==="
second = runner.call.call
puts "Latest value: #{second.outputs[:latest_value].value}"
puts "First value: #{second.outputs[:first_value].value}"
puts "History: #{second.outputs[:history].value.inspect}"
puts "Source calls: #{source_calls}"
puts "Stored versions: #{store.load_output(workflow_id: "example-versioned-inputs", node_path: [:source], version: :all).map { |entry| entry[:version] }.inspect}"
