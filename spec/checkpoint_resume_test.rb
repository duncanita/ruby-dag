# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class CheckpointResumeTest < Minitest::Test
  include TestHelpers

  def test_runner_requires_workflow_id_when_execution_store_is_enabled
    definition = build_test_workflow(fetch: {command: "echo fetch"})
    store = build_memory_store

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Runner.new(definition, parallel: false, execution_store: store)
    end

    assert_includes error.message, "workflow_id"
  end

  def test_persistent_ruby_steps_require_resume_key
    definition = build_test_workflow(
      fetch: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "ok") }}
    )
    store = build_memory_store

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

    store = build_memory_store

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

    store = build_memory_store

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
    store = build_memory_store

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

  def test_file_store_resume_reuses_completed_outputs_across_fresh_store_instances
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

    Dir.mktmpdir("dag-checkpoint-file-store") do |dir|
      first = DAG::Workflow::Runner.new(definition,
        parallel: false,
        execution_store: DAG::Workflow::ExecutionStore::FileStore.new(dir: dir),
        workflow_id: "wf-file-resume").call

      second = DAG::Workflow::Runner.new(definition,
        parallel: false,
        execution_store: DAG::Workflow::ExecutionStore::FileStore.new(dir: dir),
        workflow_id: "wf-file-resume").call

      assert first.success?
      assert second.success?
      assert_equal 1, fetch_calls
      assert_equal 1, merge_calls
      assert_equal "payload-1", second.outputs[:fetch].value
      assert_equal "merged:payload-1", second.outputs[:merge].value
    end
  end

  def test_clear_on_completion_removes_persisted_checkpoints_after_success
    calls = 0
    definition = build_test_workflow(
      fetch: {
        type: :ruby,
        resume_key: "fetch-v1",
        callable: ->(_input) do
          calls += 1
          DAG::Success.new(value: "payload-#{calls}")
        end
      }
    )
    store = build_memory_store

    first = DAG::Workflow::Runner.new(definition,
      parallel: false,
      execution_store: store,
      workflow_id: "wf-clear",
      clear_on_completion: true).call

    second = DAG::Workflow::Runner.new(definition,
      parallel: false,
      execution_store: store,
      workflow_id: "wf-clear",
      clear_on_completion: true).call

    assert first.success?
    assert second.success?
    assert_nil store.load_run("wf-clear")
    assert_equal 2, calls
    assert_equal "payload-1", first.outputs[:fetch].value
    assert_equal "payload-2", second.outputs[:fetch].value
  end
end
