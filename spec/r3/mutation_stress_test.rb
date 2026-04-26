# frozen_string_literal: true

require_relative "../test_helper"

class R3MutationStressTest < Minitest::Test
  def test_repeated_apply_attempts_against_running_workflow_all_fail_without_revision
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
    service = DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Memory::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )

    failures = 10.times.count do
      assert_raises(DAG::ConcurrentMutationError) do
        service.apply(
          workflow_id: workflow_id,
          mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :a],
          expected_revision: 1
        )
      end
    end

    assert_equal 10, failures
    assert_equal 1, storage.load_current_definition(id: workflow_id).revision
    assert(storage.load_node_states(workflow_id: workflow_id, revision: 1).values.all? { |state| state == :pending })
    assert_empty storage.read_events(workflow_id: workflow_id)
  end
end
