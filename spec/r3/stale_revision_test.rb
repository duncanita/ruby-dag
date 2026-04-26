# frozen_string_literal: true

require_relative "../test_helper"

class R3StaleRevisionTest < Minitest::Test
  def test_apply_rejects_stale_expected_revision
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)
    service = DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Null::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )

    service.apply(
      workflow_id: workflow_id,
      mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :a],
      expected_revision: 1
    )

    assert_raises(DAG::StaleRevisionError) do
      service.apply(
        workflow_id: workflow_id,
        mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :a],
        expected_revision: 1
      )
    end
    assert_equal 2, storage.load_current_definition(id: workflow_id).revision
  end
end
