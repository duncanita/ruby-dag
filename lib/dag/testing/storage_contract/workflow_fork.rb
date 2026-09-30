# frozen_string_literal: true

module DAG::Testing::StorageContract
  module WorkflowFork
    def test_contract_fork_inherits_only_committed_results_from_selected_revision
      storage = build_contract_storage
      source_definition = DAG::Workflow::Definition.new
        .add_node(:a, type: :passthrough)
        .add_node(:b, type: :passthrough)
        .add_node(:w, type: :passthrough)
        .add_edge(:a, :b)
        .add_edge(:a, :w)
      source_id = contract_create_workflow(storage, definition: source_definition)
      attempt_id = contract_begin_attempt(storage, source_id, :a)
      seed = DAG::Success[value: {seed: 7}, context_patch: {seed: 7}]
      storage.commit_attempt(attempt_id: attempt_id, result: seed, node_state: :committed,
        event: contract_event(workflow_id: source_id, node_id: :a, attempt_id: attempt_id))
      effect = contract_commit_waiting_effect(storage, source_id, :w)
      replacement = DAG::Workflow::Definition.new
        .add_node(:a, type: :passthrough)
        .add_node(:c, type: :passthrough)
        .add_node(:w, type: :passthrough)
        .add_edge(:a, :c)
        .add_edge(:a, :w)
      storage.append_revision(id: source_id, parent_revision: 1,
        definition: replacement, invalidated_node_ids: [],
        event: contract_event(type: :mutation_applied, workflow_id: source_id, revision: 2))
      target_id = "#{source_id}-fork"

      receipt = storage.fork_workflow(source_id: source_id, source_revision: 2, new_id: target_id)
      assert_equal({workflow_id: source_id, revision: 2}, receipt[:forked_from])
      assert_equal receipt[:forked_from], storage.load_workflow(id: target_id)[:forked_from]
      assert_equal 1, receipt[:revision]
      assert_equal [:a], receipt[:inherited_node_ids]
      assert_equal({a: :committed, c: :pending, w: :pending},
        storage.load_node_states(workflow_id: target_id, revision: 1))
      assert_equal [:a, :c, :w], storage.load_current_definition(id: target_id).nodes.to_a.sort
      assert_equal({a: seed}, storage.list_committed_results_for_predecessors(
        workflow_id: target_id, revision: 1, predecessors: [:a]
      ))
      assert_empty storage.list_attempts(workflow_id: target_id)
      assert_empty storage.list_effects_for_node(workflow_id: target_id, revision: 1, node_id: :w)
      assert_equal :waiting, storage.load_node_states(workflow_id: source_id, revision: 2)[:w]
      assert_equal effect.id, storage.list_effects_for_node(workflow_id: source_id, revision: 2, node_id: :w).first.id

      historical_id = "#{source_id}-historical"
      storage.fork_workflow(source_id: source_id, source_revision: 1, new_id: historical_id)
      assert_equal [:a, :b, :w], storage.load_current_definition(id: historical_id).nodes.to_a.sort
      assert_equal({a: :committed, b: :pending, w: :pending},
        storage.load_node_states(workflow_id: historical_id, revision: 1))
    end

    def test_contract_fork_errors_leave_no_partial_target
      storage = build_contract_storage
      source_id = contract_create_workflow(storage)
      target_id = "#{source_id}-fork"
      assert_raises(DAG::StaleRevisionError) do
        storage.fork_workflow(source_id: source_id, source_revision: 2, new_id: target_id)
      end
      assert_raises(DAG::UnknownWorkflowError) { storage.load_workflow(id: target_id) }
      assert_raises(ArgumentError) do
        storage.fork_workflow(source_id: source_id, source_revision: 1, new_id: target_id,
          inherit: :unknown)
      end
      assert_raises(DAG::UnknownWorkflowError) { storage.load_workflow(id: target_id) }

      storage.fork_workflow(source_id: source_id, source_revision: 1, new_id: target_id, inherit: :none)
      assert_raises(DAG::DuplicateWorkflowError) do
        storage.fork_workflow(source_id: source_id, source_revision: 1, new_id: target_id)
      end
      assert_equal({a: :pending, b: :pending}, storage.load_node_states(workflow_id: target_id, revision: 1))
    end
  end
end
