# frozen_string_literal: true

module DAG::Testing::StorageContract
  module AttemptAtomicity
    include Helpers

    def test_contract_commit_attempt_persists_result_state_node_and_event
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending,
        attempt_number: 1
      )

      stamped = storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: :a, context_patch: {a: 1}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
      )

      attempt = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).first
      assert_equal :committed, attempt[:state]
      assert_equal({a: 1}, attempt[:result].context_patch)
      assert_equal :committed, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
      assert_equal stamped, storage.read_events(workflow_id: workflow_id).last
    end

    def test_contract_abort_running_attempts_resets_current_revision_nodes
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending,
        attempt_number: 1
      )

      assert_equal [attempt_id], storage.abort_running_attempts(workflow_id: workflow_id)

      attempt = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).first
      assert_equal :aborted, attempt[:state]
      assert_equal :pending, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
      assert_equal 0, storage.count_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
    end

    def test_contract_begin_attempt_persists_supplied_attempt_number
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending,
        attempt_number: 7
      )

      attempt = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).first
      assert_equal 7, attempt[:attempt_number]
    end

    def test_contract_begin_attempt_copies_mutable_workflow_id
      storage = build_contract_storage
      workflow_id = +"wf-contract-attempt"
      storage.create_workflow(
        id: workflow_id,
        initial_definition: contract_definition,
        initial_context: {seed: 1},
        runtime_profile: contract_runtime_profile
      )
      workflow_id << "-after-create"

      attempt_workflow_id = +"wf-contract-attempt"
      attempt_id = storage.begin_attempt(
        workflow_id: attempt_workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending,
        attempt_number: 1
      )
      attempt_workflow_id << "-after-begin"

      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: :a, context_patch: {a: 1}],
        node_state: :committed,
        event: contract_event(workflow_id: "wf-contract-attempt", node_id: :a, attempt_id: attempt_id)
      )

      attempt = storage.list_attempts(workflow_id: "wf-contract-attempt", revision: 1, node_id: :a).first
      assert_equal "wf-contract-attempt", attempt.fetch(:workflow_id)
      assert_equal :committed, storage.load_node_states(workflow_id: "wf-contract-attempt", revision: 1)[:a]
    end

    def test_contract_lists_committed_results_for_predecessors_in_one_call
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      a_attempt_id = storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending,
        attempt_number: 1
      )
      b_attempt_id = storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :b,
        expected_node_state: :pending,
        attempt_number: 1
      )
      storage.commit_attempt(
        attempt_id: a_attempt_id,
        result: DAG::Success[value: :a, context_patch: {a: 1}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: a_attempt_id)
      )
      storage.commit_attempt(
        attempt_id: b_attempt_id,
        result: DAG::Success[value: :b, context_patch: {b: 2}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :b, attempt_id: b_attempt_id)
      )

      results = storage.list_committed_results_for_predecessors(
        workflow_id: workflow_id,
        revision: 1,
        predecessors: [:b, :a, :missing]
      )

      assert_equal [:b, :a], results.keys
      assert_equal({b: 2}, results.fetch(:b).context_patch)
      assert_equal({a: 1}, results.fetch(:a).context_patch)
    end

    def test_contract_committed_predecessor_selection_uses_highest_attempt_number
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      first_attempt_id = contract_begin_attempt(storage, workflow_id, :a, attempt_number: 1)
      storage.commit_attempt(
        attempt_id: first_attempt_id,
        result: DAG::Success[value: :old, context_patch: {a: :old}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: first_attempt_id)
      )
      storage.transition_node_state(workflow_id: workflow_id, revision: 1, node_id: :a, from: :committed, to: :pending)
      second_attempt_id = contract_begin_attempt(storage, workflow_id, :a, attempt_number: 2)
      storage.commit_attempt(
        attempt_id: second_attempt_id,
        result: DAG::Success[value: :new, context_patch: {a: :new}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: second_attempt_id)
      )

      results = storage.list_committed_results_for_predecessors(
        workflow_id: workflow_id,
        revision: 1,
        predecessors: [:a]
      )

      assert_equal :new, results.fetch(:a).value
      assert_equal({a: :new}, results.fetch(:a).context_patch)
    end

    def test_contract_commit_attempt_is_one_shot
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending,
        attempt_number: 1
      )
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: :a, context_patch: {}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
      )

      assert_raises(DAG::StaleStateError) do
        storage.commit_attempt(
          attempt_id: attempt_id,
          result: DAG::Failure[error: {code: :late}],
          node_state: :failed,
          event: contract_event(type: :node_failed, workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
        )
      end
    end
  end
end
