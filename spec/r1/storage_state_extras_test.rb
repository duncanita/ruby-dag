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
    assert_equal :invalidated, states[:a]
    assert_equal :pending, states[:c]
  end

  def test_append_revision_normalizes_definition_revision
    workflow_id = create_workflow(@storage, @definition)
    new_definition = @definition.add_node(:c, type: :passthrough).add_edge(:b, :c)
    assert_equal 1, new_definition.revision

    @storage.append_revision(id: workflow_id, parent_revision: 1, definition: new_definition, invalidated_node_ids: [], event: nil)

    current = @storage.load_current_definition(id: workflow_id)
    assert_equal 2, current.revision, "stored definition's :revision must match its key"
  end

  def test_create_workflow_isolates_initial_context_from_caller_mutation
    initial = {hello: "world"}
    workflow_id = SecureRandom.uuid
    @storage.create_workflow(
      id: workflow_id,
      initial_definition: @definition,
      initial_context: initial,
      runtime_profile: DAG::RuntimeProfile.default
    )
    initial[:hello] = "mutated"

    stored = @storage.load_workflow(id: workflow_id)
    assert_equal "world", stored[:initial_context][:hello]
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
      @storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 99,
        node_id: :a,
        expected_node_state: :pending,
        attempt_number: 1
      )
    end
  end

  def test_begin_attempt_state_mismatch_raises
    workflow_id = create_workflow(@storage, @definition)
    assert_raises(DAG::StaleStateError) do
      @storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :committed,
        attempt_number: 1
      )
    end
  end

  def test_commit_attempt_unknown_attempt_raises
    assert_raises(ArgumentError) do
      @storage.commit_attempt(attempt_id: "missing", result: DAG::Success[value: 1, context_patch: {}], node_state: :committed, event: build_event)
    end
  end

  def test_commit_attempt_unexpected_result_type_raises
    workflow_id = create_workflow(@storage, @definition)
    attempt_id = @storage.begin_attempt(
      workflow_id: workflow_id,
      revision: 1,
      node_id: :a,
      expected_node_state: :pending,
      attempt_number: 1
    )
    assert_raises(ArgumentError) do
      @storage.commit_attempt(attempt_id: attempt_id, result: :not_a_result, node_state: :committed, event: build_event(workflow_id: workflow_id))
    end
  end

  def test_commit_attempt_rejects_node_state_that_does_not_match_result
    workflow_id = create_workflow(@storage, @definition)
    attempt_id = @storage.begin_attempt(
      workflow_id: workflow_id,
      revision: 1,
      node_id: :a,
      expected_node_state: :pending,
      attempt_number: 1
    )

    assert_raises(ArgumentError) do
      @storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: 1, context_patch: {}],
        node_state: :pending,
        event: build_event(workflow_id: workflow_id)
      )
    end
  end

  def test_abort_running_attempts_marks_running_as_aborted
    workflow_id = create_workflow(@storage, @definition)
    attempt_id = @storage.begin_attempt(
      workflow_id: workflow_id,
      revision: 1,
      node_id: :a,
      expected_node_state: :pending,
      attempt_number: 1
    )
    aborted = @storage.abort_running_attempts(workflow_id: workflow_id)
    assert_includes aborted, attempt_id
  end

  def test_prepare_workflow_retry_unknown_workflow_raises
    assert_raises(DAG::UnknownWorkflowError) { @storage.prepare_workflow_retry(id: "ghost") }
  end

  def test_prepare_workflow_retry_enforces_budget_inside_atomic_boundary
    workflow_id = create_workflow(@storage, @definition,
      runtime_profile: DAG::RuntimeProfile[
        durability: :ephemeral,
        max_attempts_per_node: 1,
        max_workflow_retries: 1,
        event_bus_kind: :null
      ])
    @storage.transition_workflow_state(id: workflow_id, from: :pending, to: :failed)
    @storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)
    @storage.transition_workflow_state(id: workflow_id, from: :pending, to: :failed)

    assert_raises(DAG::WorkflowRetryExhaustedError) do
      @storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)
    end
    workflow = @storage.load_workflow(id: workflow_id)
    assert_equal :failed, workflow[:state]
    assert_equal 1, workflow[:workflow_retry_count]
  end

  def test_prepare_workflow_retry_transitions_workflow_and_rejects_duplicate_prepare
    workflow_id = create_workflow(@storage, @definition,
      runtime_profile: DAG::RuntimeProfile[
        durability: :ephemeral,
        max_attempts_per_node: 1,
        max_workflow_retries: 2,
        event_bus_kind: :null
      ])
    attempt_id = @storage.begin_attempt(
      workflow_id: workflow_id,
      revision: 1,
      node_id: :a,
      expected_node_state: :pending,
      attempt_number: 1
    )
    @storage.commit_attempt(
      attempt_id: attempt_id,
      result: DAG::Failure[error: {code: :boom}, retriable: true],
      node_state: :failed,
      event: build_event(:node_failed, workflow_id: workflow_id)
    )
    @storage.transition_workflow_state(id: workflow_id, from: :pending, to: :failed)

    result = @storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)

    assert_equal :pending, result[:state]
    assert_equal [:a], result[:reset]
    assert_equal 1, result[:workflow_retry_count]
    assert_equal :pending, @storage.load_workflow(id: workflow_id)[:state]
    assert_equal :pending, node_state(@storage, workflow_id, :a)
    assert_equal :aborted, @storage.list_attempts(workflow_id: workflow_id, node_id: :a).first[:state]
    assert_raises(DAG::StaleStateError) do
      @storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)
    end
    assert_equal 1, @storage.load_workflow(id: workflow_id)[:workflow_retry_count]
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

  private

  def create_workflow_with_id(id)
    @storage.create_workflow(
      id: id,
      initial_definition: @definition,
      initial_context: {},
      runtime_profile: DAG::RuntimeProfile.default
    )
  end
end
