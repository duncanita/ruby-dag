# frozen_string_literal: true

module StorageContract
  module AttemptAtomicity
    include Helpers

    def test_contract_commit_attempt_persists_result_state_node_and_event
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending
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
        expected_node_state: :pending
      )

      assert_equal [attempt_id], storage.abort_running_attempts(workflow_id: workflow_id)

      attempt = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).first
      assert_equal :aborted, attempt[:state]
      assert_equal :pending, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
      assert_equal 0, storage.count_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
    end
  end
end
