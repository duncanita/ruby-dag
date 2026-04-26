# frozen_string_literal: true

module StorageContract
  module RevisionCAS
    include Helpers

    def test_contract_append_revision_rejects_stale_parent
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      next_definition = contract_definition.add_node(:c, type: :passthrough).add_edge(:b, :c)

      assert_raises(DAG::StaleRevisionError) do
        storage.append_revision(
          id: workflow_id,
          parent_revision: 99,
          definition: next_definition,
          invalidated_node_ids: [],
          event: contract_event(workflow_id: workflow_id)
        )
      end
    end

    def test_contract_append_revision_advances_revision_and_carries_state
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending
      )
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: :a, context_patch: {}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
      )

      next_definition = contract_definition.add_node(:c, type: :passthrough).add_edge(:b, :c)
      storage.append_revision(
        id: workflow_id,
        parent_revision: 1,
        definition: next_definition,
        invalidated_node_ids: [:b],
        event: contract_event(type: :mutation_applied, workflow_id: workflow_id)
      )

      states = storage.load_node_states(workflow_id: workflow_id, revision: 2)
      assert_equal :committed, states[:a]
      assert_equal :pending, states[:b]
      assert_equal :pending, states[:c]
      assert_equal 2, storage.load_current_definition(id: workflow_id).revision
    end
  end
end
