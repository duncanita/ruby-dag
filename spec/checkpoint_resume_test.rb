# frozen_string_literal: true

require_relative "test_helper"

class CheckpointResumeTest < Minitest::Test
  include TestHelpers

  def test_runner_requires_workflow_id_when_execution_store_is_enabled
    definition = build_test_workflow(fetch: {command: "echo fetch"})
    store = DAG::Workflow::ExecutionStore::MemoryStore.new

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Runner.new(definition, parallel: false, execution_store: store)
    end

    assert_includes error.message, "workflow_id"
  end

  def test_persistent_ruby_steps_require_resume_key
    definition = build_test_workflow(
      fetch: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "ok") }}
    )
    store = DAG::Workflow::ExecutionStore::MemoryStore.new

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Runner.new(definition,
        parallel: false,
        execution_store: store,
        workflow_id: "wf-1")
    end

    assert_includes error.message, "resume_key"
    assert_includes error.message, "fetch"
  end

  def test_successful_outputs_are_reused_on_resume
    fetch_calls = 0
    merge_calls = 0

    definition = build_test_workflow(
      fetch: {
        type: :ruby,
        resume_key: "fetch-v1",
        callable: ->(_input) do
          fetch_calls += 1
          DAG::Success.new(value: "payload-#{fetch_calls}")
        end
      },
      merge: {
        type: :ruby,
        depends_on: [:fetch],
        resume_key: "merge-v1",
        callable: ->(input) do
          merge_calls += 1
          DAG::Success.new(value: "merged:#{input[:fetch]}")
        end
      }
    )

    store = DAG::Workflow::ExecutionStore::MemoryStore.new

    first = DAG::Workflow::Runner.new(definition,
      parallel: false,
      execution_store: store,
      workflow_id: "wf-resume").call

    second = DAG::Workflow::Runner.new(definition,
      parallel: false,
      execution_store: store,
      workflow_id: "wf-resume").call

    assert_equal 1, fetch_calls
    assert_equal 1, merge_calls
    assert first.success?
    assert second.success?
    assert_equal "payload-1", first.outputs[:fetch].value
    assert_equal "payload-1", second.outputs[:fetch].value
    assert_equal "merged:payload-1", second.outputs[:merge].value
  end

  def test_stored_failures_are_not_reused
    attempts = 0

    definition = build_test_workflow(
      flaky: {
        type: :ruby,
        resume_key: "flaky-v1",
        callable: ->(_input) do
          attempts += 1
          if attempts == 1
            DAG::Failure.new(error: {code: :boom, message: "first run fails"})
          else
            DAG::Success.new(value: "recovered")
          end
        end
      }
    )

    store = DAG::Workflow::ExecutionStore::MemoryStore.new

    first = DAG::Workflow::Runner.new(definition,
      parallel: false,
      execution_store: store,
      workflow_id: "wf-flaky").call

    second = DAG::Workflow::Runner.new(definition,
      parallel: false,
      execution_store: store,
      workflow_id: "wf-flaky").call

    assert first.failure?
    assert second.success?
    assert_equal 2, attempts
    assert_equal "recovered", second.outputs[:flaky].value
  end

  def test_fingerprint_mismatch_raises_before_any_step_runs
    calls = 0
    store = DAG::Workflow::ExecutionStore::MemoryStore.new

    original = build_test_workflow(
      fetch: {
        type: :ruby,
        resume_key: "fetch-v1",
        callable: ->(_input) { DAG::Success.new(value: "ok") }
      }
    )

    changed = build_test_workflow(
      fetch: {
        type: :ruby,
        resume_key: "fetch-v2",
        callable: ->(_input) do
          calls += 1
          DAG::Success.new(value: "changed")
        end
      }
    )

    DAG::Workflow::Runner.new(original,
      parallel: false,
      execution_store: store,
      workflow_id: "wf-fingerprint").call

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Runner.new(changed,
        parallel: false,
        execution_store: store,
        workflow_id: "wf-fingerprint").call
    end

    assert_equal 0, calls
    assert_includes error.message, "fingerprint"
  end
end
