# frozen_string_literal: true

module DAG::Testing::StorageContract
  module WorkflowLifecycle
    include Helpers

    def test_contract_create_load_and_transition_workflow
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)

      workflow = storage.load_workflow(id: workflow_id)
      assert_equal :pending, workflow[:state]
      assert_equal 1, workflow[:current_revision]
      assert_equal({seed: 1}, workflow[:initial_context])

      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
      assert_equal :running, storage.load_workflow(id: workflow_id)[:state]
    end

    def test_contract_transition_workflow_state_appends_optional_event_atomically
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      event = contract_event(type: :workflow_started, workflow_id: workflow_id)

      result = storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running, event: event)

      assert_equal :running, result.fetch(:state)
      assert_equal result.fetch(:event), storage.read_events(workflow_id: workflow_id).last
      assert_equal :workflow_started, result.fetch(:event).type
      events_before = storage.read_events(workflow_id: workflow_id)

      assert_raises(DAG::StaleStateError) do
        storage.transition_workflow_state(
          id: workflow_id,
          from: :pending,
          to: :completed,
          event: contract_event(type: :workflow_completed, workflow_id: workflow_id)
        )
      end

      assert_equal :running, storage.load_workflow(id: workflow_id).fetch(:state)
      assert_equal events_before, storage.read_events(workflow_id: workflow_id)
    end

    def test_contract_loads_isolated_node_state_copy
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)

      states = storage.load_node_states(workflow_id: workflow_id, revision: 1)
      assert states.frozen?
      mutable_states = states.dup
      mutable_states[:a] = :committed

      assert_equal :pending, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
    end
  end
end
