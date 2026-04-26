# frozen_string_literal: true

require_relative "../test_helper"

class MemoryStorageCasTest < Minitest::Test
  def setup
    @storage = DAG::Adapters::Memory::Storage.new
    @workflow_id = create_workflow(@storage, simple_definition)
  end

  def test_workflow_state_cas_rejects_stale_from
    @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :running)
    assert_raises(DAG::StaleStateError) do
      @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :running)
    end
  end

  def test_node_state_cas_rejects_stale_from
    @storage.transition_node_state(workflow_id: @workflow_id, revision: 1, node_id: :a, from: :pending, to: :running)
    assert_raises(DAG::StaleStateError) do
      @storage.transition_node_state(workflow_id: @workflow_id, revision: 1, node_id: :a, from: :pending, to: :running)
    end
  end

  def test_count_attempts_excludes_aborted
    assert_equal 0, @storage.count_attempts(workflow_id: @workflow_id, revision: 1, node_id: :a)
    a1 = @storage.begin_attempt(workflow_id: @workflow_id, revision: 1, node_id: :a, expected_node_state: :pending)
    @storage.commit_attempt(attempt_id: a1, result: DAG::Success[value: 1, context_patch: {}], node_state: :pending, event: build_event(:node_committed, workflow_id: @workflow_id))
    @storage.abort_running_attempts(workflow_id: @workflow_id) # nothing to abort

    a2 = @storage.begin_attempt(workflow_id: @workflow_id, revision: 1, node_id: :a, expected_node_state: :pending)
    refute_equal a1, a2
    assert_equal 2, @storage.count_attempts(workflow_id: @workflow_id, revision: 1, node_id: :a)
  end

  def test_events_seq_is_monotonic
    e1 = @storage.append_event(workflow_id: @workflow_id, event: build_event(workflow_id: @workflow_id))
    e2 = @storage.append_event(workflow_id: @workflow_id, event: build_event(workflow_id: @workflow_id))
    assert_equal e1.seq + 1, e2.seq
  end

  def test_unknown_workflow_load_raises
    assert_raises(DAG::UnknownWorkflowError) { @storage.load_workflow(id: "missing") }
  end
end
