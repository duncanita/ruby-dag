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

  def test_apply_rechecks_workflow_state_at_revision_append_boundary
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)
    racing_storage = StateRacingStorage.new(storage, workflow_id: workflow_id, from: :paused, to: :running)
    event_bus = DAG::Adapters::Memory::EventBus.new
    service = DAG::MutationService.new(
      storage: racing_storage,
      event_bus: event_bus,
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
    assert_empty event_bus.events
  end

  class StateRacingStorage
    def initialize(storage, workflow_id:, from:, to:)
      @storage = storage
      @workflow_id = workflow_id
      @from = from
      @to = to
      @raced = false
    end

    def append_revision_if_workflow_state(**kwargs)
      unless @raced
        @raced = true
        @storage.transition_workflow_state(id: @workflow_id, from: @from, to: @to)
      end
      @storage.append_revision_if_workflow_state(**kwargs)
    end

    def method_missing(name, ...)
      @storage.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @storage.respond_to?(name, include_private) || super
    end
  end
end
