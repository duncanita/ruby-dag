# frozen_string_literal: true

require_relative "test_helper"

class PauseResumeTest < Minitest::Test
  include TestHelpers

  def test_pause_flag_stops_before_next_layer_and_persists_paused_status
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    definition = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        resume_key: "fetch-v1",
        callable: ->(_input) { DAG::Success.new(value: "fetched") }
      },
      transform: {
        type: :ruby,
        depends_on: [:fetch],
        resume_key: "transform-v1",
        callable: ->(input) { DAG::Success.new(value: input[:fetch].upcase) }
      }
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      workflow_id: "wf-pause",
      execution_store: store,
      on_step_finish: lambda do |name, _result|
        store.set_pause_flag(workflow_id: "wf-pause", paused: true) if name == :fetch
      end).call

    assert_equal :paused, result.status
    assert result.paused?
    assert_equal "fetched", result.outputs[:fetch].value
    refute result.outputs.key?(:transform)
    assert_equal :paused, store.load_run("wf-pause")[:workflow_status]
  end

  def test_pause_flag_is_observed_between_layers_not_mid_layer
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    definition = DAG::Workflow::Loader.from_hash(
      a: {
        type: :ruby,
        resume_key: "a-v1",
        callable: ->(_input) { DAG::Success.new(value: "A") }
      },
      b: {
        type: :ruby,
        resume_key: "b-v1",
        callable: ->(_input) { DAG::Success.new(value: "B") }
      },
      c: {
        type: :ruby,
        depends_on: [:a, :b],
        resume_key: "c-v1",
        callable: ->(input) { DAG::Success.new(value: input.values.join("+")) }
      }
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      workflow_id: "wf-pause-layer",
      execution_store: store,
      on_step_finish: lambda do |name, _result|
        store.set_pause_flag(workflow_id: "wf-pause-layer", paused: true) if name == :a
      end).call

    assert_equal :paused, result.status
    assert_equal "A", result.outputs[:a].value
    assert_equal "B", result.outputs[:b].value
    refute result.outputs.key?(:c)
  end

  def test_resume_after_clearing_pause_flag_reuses_completed_outputs
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    fetch_calls = 0
    transform_calls = 0
    definition = DAG::Workflow::Loader.from_hash(
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

    paused = DAG::Workflow::Runner.new(definition,
      parallel: false,
      workflow_id: "wf-resume",
      execution_store: store,
      on_step_finish: lambda do |name, _result|
        store.set_pause_flag(workflow_id: "wf-resume", paused: true) if name == :fetch
      end).call

    store.set_pause_flag(workflow_id: "wf-resume", paused: false)
    resumed = DAG::Workflow::Runner.new(definition,
      parallel: false,
      workflow_id: "wf-resume",
      execution_store: store).call

    assert_equal :paused, paused.status
    assert_equal :completed, resumed.status
    assert_equal "PAYLOAD", resumed.outputs[:transform].value
    assert_equal 1, fetch_calls
    assert_equal 1, transform_calls
  end
end
