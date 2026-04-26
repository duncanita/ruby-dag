# frozen_string_literal: true

require_relative "../test_helper"

class R3MutationActiveRunGuardTest < Minitest::Test
  def test_apply_while_workflow_running_raises_concurrent_mutation_error
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
    service = DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Memory::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )

    assert_raises(DAG::ConcurrentMutationError) do
      service.apply(
        workflow_id: workflow_id,
        mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :a],
        expected_revision: 1
      )
    end
    assert_equal 1, storage.load_current_definition(id: workflow_id).revision
    assert_empty storage.read_events(workflow_id: workflow_id)
  end
end
