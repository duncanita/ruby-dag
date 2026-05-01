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
        expected_node_state: :pending,
        attempt_number: 1
      )
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: :a, context_patch: {}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
      )

      next_definition = contract_definition.add_node(:c, type: :passthrough).add_edge(:b, :c)
      result = storage.append_revision(
        id: workflow_id,
        parent_revision: 1,
        definition: next_definition,
        invalidated_node_ids: [:b],
        event: contract_event(type: :mutation_applied, workflow_id: workflow_id)
      )

      states = storage.load_node_states(workflow_id: workflow_id, revision: 2)
      assert_equal :committed, states[:a]
      assert_equal :invalidated, states[:b]
      assert_equal :pending, states[:c]
      assert_equal 2, storage.load_current_definition(id: workflow_id).revision
      assert_equal :mutation_applied, result[:event].type
      assert_equal result[:event], storage.read_events(workflow_id: workflow_id).last
    end

    def test_contract_append_revision_if_workflow_state_rejects_disallowed_state_atomically
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
      next_definition = contract_definition.add_node(:c, type: :passthrough).add_edge(:b, :c)

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

      assert_equal 1, storage.load_current_definition(id: workflow_id).revision
      assert_empty storage.read_events(workflow_id: workflow_id)
    end

    def test_contract_append_revision_if_workflow_state_advances_when_allowed
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)
      next_definition = contract_definition.add_node(:c, type: :passthrough).add_edge(:b, :c)

      result = storage.append_revision_if_workflow_state(
        id: workflow_id,
        allowed_states: %i[paused waiting],
        parent_revision: 1,
        definition: next_definition,
        invalidated_node_ids: [:b],
        event: contract_event(type: :mutation_applied, workflow_id: workflow_id)
      )

      assert_equal 2, result.fetch(:revision)
      assert_equal 2, storage.load_current_definition(id: workflow_id).revision
      assert_equal :mutation_applied, storage.read_events(workflow_id: workflow_id).last.type
    end
  end
end
