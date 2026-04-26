# frozen_string_literal: true

require_relative "../test_helper"

class StorageStateExtrasTest < Minitest::Test
  def setup
    @storage = DAG::Adapters::Memory::Storage.new
    @definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_edge(:a, :b)
  end

  def test_create_workflow_rejects_duplicate_id
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(ArgumentError) { create_workflow_with_id(workflow_id) }
  end

  def test_create_workflow_rejects_non_definition
    assert_raises(ArgumentError) do
      @storage.create_workflow(
        id: "x",
        initial_definition: :not_a_definition,
        initial_context: {},
        runtime_profile: DAG::RuntimeProfile.default
      )
    end
  end

  def test_create_workflow_rejects_non_runtime_profile
    assert_raises(ArgumentError) do
      @storage.create_workflow(
        id: "x",
        initial_definition: @definition,
        initial_context: {},
        runtime_profile: :not_a_profile
      )
    end
  end

  def test_create_workflow_rejects_non_json_safe_initial_context
    assert_raises(ArgumentError) do
      @storage.create_workflow(
        id: "x",
        initial_definition: @definition,
        initial_context: {t: Time.now},
        runtime_profile: DAG::RuntimeProfile.default
      )
    end
  end

  def test_load_revision_returns_definition
    workflow_id = create_workflow(@storage, @definition)
    revision = @storage.load_revision(id: workflow_id, revision: 1)
    assert_kind_of DAG::Workflow::Definition, revision
  end

  def test_load_revision_unknown_raises
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(DAG::StaleRevisionError) { @storage.load_revision(id: workflow_id, revision: 99) }
  end

  def test_append_revision_with_stale_parent_raises
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(DAG::StaleRevisionError) do
      @storage.append_revision(id: workflow_id, parent_revision: 99, definition: @definition, invalidated_node_ids: [], event: nil)
    end
  end

  def test_append_revision_increments_and_invalidates
    workflow_id = create_workflow(@storage, @definition)
    new_definition = @definition.add_node(:c, type: :passthrough).add_edge(:b, :c)
    result = @storage.append_revision(
      id: workflow_id,
      parent_revision: 1,
      definition: new_definition,
      invalidated_node_ids: [:a],
      event: nil
    )
    assert_equal 2, result[:revision]
    states = @storage.load_node_states(workflow_id: workflow_id, revision: 2)
    assert_equal :pending, states[:a]
    assert_equal :pending, states[:c]
  end

  def test_load_node_states_unknown_revision_raises
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(DAG::StaleRevisionError) { @storage.load_node_states(workflow_id: workflow_id, revision: 99) }
  end

  def test_transition_node_state_unknown_revision_raises
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(DAG::StaleRevisionError) do
      @storage.transition_node_state(workflow_id: workflow_id, revision: 99, node_id: :a, from: :pending, to: :running)
    end
  end

  def test_begin_attempt_unknown_revision_raises
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(DAG::StaleRevisionError) do
      @storage.begin_attempt(workflow_id: workflow_id, revision: 99, node_id: :a, attempt_number: 1, expected_node_state: :pending)
    end
  end

  def test_begin_attempt_state_mismatch_raises
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(DAG::StaleStateError) do
      @storage.begin_attempt(workflow_id: workflow_id, revision: 1, node_id: :a, attempt_number: 1, expected_node_state: :committed)
    end
  end

  def test_commit_attempt_unknown_attempt_raises
    assert_raises(ArgumentError) do
      @storage.commit_attempt(attempt_id: "missing", result: DAG::Success[value: 1, context_patch: {}], node_state: :committed)
    end
  end

  def test_commit_attempt_unexpected_result_type_raises
    workflow_id = create_workflow(@storage, @definition)
    attempt_id = @storage.begin_attempt(workflow_id: workflow_id, revision: 1, node_id: :a, attempt_number: 1, expected_node_state: :pending)
    assert_raises(ArgumentError) do
      @storage.commit_attempt(attempt_id: attempt_id, result: :not_a_result, node_state: :committed)
    end
  end

  def test_abort_running_attempts_marks_running_as_aborted
    workflow_id = create_workflow(@storage, @definition)
    attempt_id = @storage.begin_attempt(workflow_id: workflow_id, revision: 1, node_id: :a, attempt_number: 1, expected_node_state: :pending)
    aborted = @storage.abort_running_attempts(workflow_id: workflow_id)
    assert_includes aborted, attempt_id
  end

  def test_increment_workflow_retry_unknown_workflow_raises
    assert_raises(DAG::UnknownWorkflowError) { @storage.increment_workflow_retry(id: "ghost") }
  end

  def test_reset_failed_nodes_unknown_revision_raises
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(DAG::StaleRevisionError) { @storage.reset_failed_nodes(id: workflow_id, revision: 99) }
  end

  def test_read_events_filters_after_seq_and_limit
    workflow_id = create_workflow(@storage, @definition)
    e1 = @storage.append_event(workflow_id: workflow_id, event: build_event(:node_started))
    @storage.append_event(workflow_id: workflow_id, event: build_event(:node_committed))
    @storage.append_event(workflow_id: workflow_id, event: build_event(:workflow_completed))

    after = @storage.read_events(workflow_id: workflow_id, after_seq: e1.seq)
    assert_equal [:node_committed, :workflow_completed], after.map(&:type)

    limited = @storage.read_events(workflow_id: workflow_id, limit: 1)
    assert_equal 1, limited.size
  end

  def test_last_event_seq_returns_monotonic_seq_or_nil
    workflow_id = create_workflow(@storage, @definition)
    assert_nil @storage.last_event_seq(workflow_id: workflow_id)
    @storage.append_event(workflow_id: workflow_id, event: build_event(:node_started))
    @storage.append_event(workflow_id: workflow_id, event: build_event(:node_committed))
    assert_equal 2, @storage.last_event_seq(workflow_id: workflow_id)
  end

  def test_latest_committed_attempt_returns_most_recent_committed
    workflow_id = create_workflow(@storage, @definition)
    a1 = @storage.begin_attempt(workflow_id: workflow_id, revision: 1, node_id: :a, attempt_number: 1, expected_node_state: :pending)
    @storage.commit_attempt(attempt_id: a1, result: DAG::Failure[error: {code: :x, message: "y"}, retriable: true], node_state: :pending)

    assert_nil @storage.latest_committed_attempt(workflow_id: workflow_id, revision: 1, node_id: :a)

    a2 = @storage.begin_attempt(workflow_id: workflow_id, revision: 1, node_id: :a, attempt_number: 2, expected_node_state: :pending)
    @storage.commit_attempt(attempt_id: a2, result: DAG::Success[value: 42, context_patch: {x: 1}], node_state: :committed)

    latest = @storage.latest_committed_attempt(workflow_id: workflow_id, revision: 1, node_id: :a)
    assert_equal a2, latest[:attempt_id]
    assert_equal 42, latest[:result].value
  end

  private

  def create_workflow_with_id(id)
    @storage.create_workflow(
      id: id,
      initial_definition: @definition,
      initial_context: {},
      runtime_profile: DAG::RuntimeProfile.default
    )
  end

  def build_event(type)
    DAG::Event[type: type, workflow_id: "x", revision: 1, at_ms: 0, payload: {}]
  end
end
