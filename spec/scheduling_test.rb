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

  def test_waiting_nodes_do_not_stop_independent_runnable_future_layers
    clock = FakeClock.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)

    definition = DAG::Workflow::Loader.from_hash(
      gated: {
        type: :ruby,
        schedule: {not_before: future_time},
        callable: ->(_input) { DAG::Success.new(value: "later") }
      },
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "ready") }
      },
      transform: {
        type: :ruby,
        depends_on: [:fetch],
        callable: ->(input) { DAG::Success.new(value: input[:fetch].upcase) }
      }
    )

    result = DAG::Workflow::Runner.new(definition, parallel: false, clock: clock).call

    assert_equal :waiting, result.status
    assert_equal "ready", result.outputs[:fetch].value
    assert_equal "READY", result.outputs[:transform].value
    refute result.outputs.key?(:gated)
    assert_equal [[:gated]], result.waiting_nodes
  end

  def test_failure_takes_precedence_over_waiting_and_clears_waiting_nodes
    clock = FakeClock.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)

    definition = DAG::Workflow::Loader.from_hash(
      gated: {
        type: :ruby,
        schedule: {not_before: future_time},
        callable: ->(_input) { DAG::Success.new(value: "later") }
      },
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "ready") }
      },
      explode: {
        type: :ruby,
        depends_on: [:fetch],
        callable: ->(_input) { DAG::Failure.new(error: {code: :boom, message: "explode"}) }
      }
    )

    result = DAG::Workflow::Runner.new(definition, parallel: false, clock: clock).call

    assert_equal :failed, result.status
    assert_equal :explode, result.error[:failed_node]
    assert_equal [], result.waiting_nodes
    assert_equal "ready", result.outputs[:fetch].value
    refute result.outputs.key?(:explode)
    refute result.outputs.key?(:gated)
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

  def test_not_after_fails_before_executing_late_work
    clock = FakeClock.new(Time.utc(2026, 4, 15, 10, 0, 1), 0.0)
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    calls = 0

    definition = DAG::Workflow::Loader.from_hash(
      scheduled: {
        type: :ruby,
        resume_key: "scheduled-v1",
        schedule: {not_after: Time.utc(2026, 4, 15, 10, 0, 0)},
        callable: ->(_input) do
          calls += 1
          DAG::Success.new(value: "too-late")
        end
      }
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-not-after",
      execution_store: store).call

    assert_equal :failed, result.status
    assert_equal :scheduled, result.error[:failed_node]
    assert_equal :deadline_exceeded, result.error[:step_error][:code]
    assert_match(/schedule\.not_after/, result.error[:step_error][:message])
    assert_equal [], result.waiting_nodes
    refute result.outputs.key?(:scheduled)
    assert_equal 0, calls

    run = store.load_run("wf-not-after")
    node = store.load_node(workflow_id: "wf-not-after", node_path: [:scheduled])
    assert_equal :failed, run[:workflow_status]
    assert_equal :failed, node[:state]
    assert_equal :deadline_exceeded, node[:reason][:code]
  end

  def test_not_after_failure_wins_over_waiting_nodes
    clock = FakeClock.new(Time.utc(2026, 4, 15, 10, 0, 1), 0.0)

    definition = DAG::Workflow::Loader.from_hash(
      waiting: {
        type: :ruby,
        schedule: {not_before: Time.utc(2026, 4, 15, 11, 0, 0)},
        callable: ->(_input) { DAG::Success.new(value: "later") }
      },
      expired: {
        type: :ruby,
        schedule: {not_after: Time.utc(2026, 4, 15, 10, 0, 0)},
        callable: ->(_input) { DAG::Success.new(value: "too-late") }
      }
    )

    result = DAG::Workflow::Runner.new(definition, parallel: false, clock: clock).call

    assert_equal :failed, result.status
    assert_equal :expired, result.error[:failed_node]
    assert_equal :deadline_exceeded, result.error[:step_error][:code]
    assert_equal [], result.waiting_nodes
    refute result.outputs.key?(:waiting)
    refute result.outputs.key?(:expired)
  end

  def test_ttl_expiry_reexecutes_instead_of_reusing_output
    clock = FakeClock.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    calls = 0

    definition = DAG::Workflow::Loader.from_hash(
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

    first = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-ttl",
      execution_store: store).call

    clock.advance_wall(120)
    second = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-ttl",
      execution_store: store).call

    clock.advance_wall(240)
    third = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-ttl",
      execution_store: store).call

    node = store.load_node(workflow_id: "wf-ttl", node_path: [:cached])

    assert_equal "run-1", first.outputs[:cached].value
    assert_equal "run-1", second.outputs[:cached].value
    assert_equal "run-2", third.outputs[:cached].value
    assert_equal 2, calls
    assert_equal :completed, node[:state]
    assert_equal :ttl_expired, node[:stale_cause][:code]
  end

  def test_ttl_string_values_are_supported
    clock = FakeClock.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    calls = 0

    definition = DAG::Workflow::Loader.from_hash(
      cached: {
        type: :ruby,
        resume_key: "cached-v1",
        schedule: {ttl: "5"},
        callable: ->(_input) do
          calls += 1
          DAG::Success.new(value: "run-#{calls}")
        end
      }
    )

    first = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-ttl-string",
      execution_store: store).call

    clock.advance_wall(10)

    second = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      workflow_id: "wf-ttl-string",
      execution_store: store).call

    assert_equal "run-1", first.outputs[:cached].value
    assert_equal "run-2", second.outputs[:cached].value
    assert_equal 2, calls
  end
end
