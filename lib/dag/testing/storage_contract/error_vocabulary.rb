# frozen_string_literal: true

module DAG::Testing::StorageContract
  module ErrorVocabulary
    include Helpers

    def test_contract_uses_standard_storage_error_classes
      storage = build_contract_storage

      assert_raises(DAG::UnknownWorkflowError) { storage.load_workflow(id: "missing") }

      workflow_id = contract_create_workflow(storage)
      assert_raises(DAG::StaleStateError) do
        storage.transition_workflow_state(id: workflow_id, from: :running, to: :completed)
      end

      next_definition = contract_definition.add_node(:c, type: :passthrough).add_edge(:b, :c)
      assert_raises(DAG::StaleRevisionError) do
        storage.append_revision(
          id: workflow_id,
          parent_revision: 99,
          definition: next_definition,
          invalidated_node_ids: [],
          event: contract_event(type: :mutation_applied, workflow_id: workflow_id)
        )
      end

      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
      assert_raises(DAG::ConcurrentMutationError) do
        storage.append_revision_if_workflow_state(
          id: workflow_id,
          allowed_states: %i[paused waiting],
          parent_revision: 1,
          definition: next_definition,
          invalidated_node_ids: [:b],
          event: contract_event(type: :mutation_applied, workflow_id: workflow_id)
        )
      end
    end
  end
end
