# frozen_string_literal: true

require_relative "test_helper"

class SchedulingTest < Minitest::Test
  include TestHelpers

  FakeClock = Struct.new(:wall_time, :mono_time) do
    def wall_now = wall_time
    def monotonic_now = mono_time
    def advance_wall(seconds) = self.wall_time += seconds
  end

  def test_not_before_returns_waiting_status_and_waiting_nodes
    clock = FakeClock.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)
    store = DAG::Workflow::ExecutionStore::MemoryStore.new

    definition = DAG::Workflow::Loader.from_hash(
      scheduled: {
        type: :ruby,
        resume_key: "scheduled-v1",
        schedule: {not_before: future_time},
        callable: ->(_input) { DAG::Success.new(value: "done") }
      }
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-waiting",
      execution_store: store).call

    assert_equal :waiting, result.status
    assert result.waiting?
    assert_equal [[:scheduled]], result.waiting_nodes
    refute result.outputs.key?(:scheduled)

    run = store.load_run("wf-waiting")
    assert_equal :waiting, run[:workflow_status]
    assert_equal [[:scheduled]], run[:waiting_nodes]
  end

  def test_not_before_does_not_block_other_runnable_layers
    clock = FakeClock.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)

    definition = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "ready") }
      },
      scheduled: {
        type: :ruby,
        depends_on: [:fetch],
        schedule: {not_before: future_time},
        callable: ->(input) { DAG::Success.new(value: input[:fetch].upcase) }
      }
    )

    result = DAG::Workflow::Runner.new(definition, parallel: false, clock: clock).call

    assert_equal :waiting, result.status
    assert_equal "ready", result.outputs[:fetch].value
    refute result.outputs.key?(:scheduled)
    assert_equal [[:scheduled]], result.waiting_nodes
  end

  def test_not_before_run_completes_after_clock_advances_past_gate
    clock = FakeClock.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    calls = 0

    definition = DAG::Workflow::Loader.from_hash(
      scheduled: {
        type: :ruby,
        resume_key: "scheduled-v1",
        schedule: {not_before: future_time},
        callable: ->(_input) do
          calls += 1
          DAG::Success.new(value: "done")
        end
      }
    )

    first = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-waiting-resume",
      execution_store: store).call

    clock.advance_wall(3600)

    second = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-waiting-resume",
      execution_store: store).call

    assert_equal :waiting, first.status
    assert_equal :completed, second.status
    assert_equal "done", second.outputs[:scheduled].value
    assert_equal 1, calls
  end
end
