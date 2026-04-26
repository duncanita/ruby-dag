# frozen_string_literal: true

require_relative "../test_helper"

class ResumeAfterCrashTest < Minitest::Test
  def test_crash_before_b_commit_resumes_from_b
    storage = DAG::Adapters::Memory::CrashableStorage.new(
      crash_on: {method: :commit_attempt, node_id: :b, before_commit: true}
    )
    call_log = []
    registry = registry_with_logging_step(call_log)
    workflow_id = create_workflow(storage, logging_chain)

    assert_raises(DAG::Adapters::Memory::SimulatedCrash) do
      build_runner(storage: storage, registry: registry).call(workflow_id)
    end

    healthy_storage = storage.snapshot_to_healthy
    result = build_runner(storage: healthy_storage, registry: registry).resume(workflow_id)

    assert_equal :completed, result.state
    assert_equal [:a, :b, :b, :c], call_log
    assert_equal :committed, node_state(healthy_storage, workflow_id, :b)

    b_attempts = healthy_storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :b)
    assert_equal [:aborted, :committed], b_attempts.map { |attempt| attempt[:state] }
  end

  def test_crash_after_b_commit_resumes_from_c
    storage = DAG::Adapters::Memory::CrashableStorage.new(
      crash_on: {method: :commit_attempt, node_id: :b, after_commit: true}
    )
    call_log = []
    registry = registry_with_logging_step(call_log)
    workflow_id = create_workflow(storage, logging_chain)

    assert_raises(DAG::Adapters::Memory::SimulatedCrash) do
      build_runner(storage: storage, registry: registry).call(workflow_id)
    end

    healthy_storage = storage.snapshot_to_healthy
    result = build_runner(storage: healthy_storage, registry: registry).resume(workflow_id)

    assert_equal :completed, result.state
    assert_equal [:a, :b, :c], call_log
    assert_equal :committed, node_state(healthy_storage, workflow_id, :b)
    assert_equal :committed, node_state(healthy_storage, workflow_id, :c)
  end

  private

  def logging_chain
    DAG::Workflow::Definition.new
      .add_node(:a, type: :logging)
      .add_node(:b, type: :logging)
      .add_node(:c, type: :logging)
      .add_edge(:a, :b)
      .add_edge(:b, :c)
  end
end
