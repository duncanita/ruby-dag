# frozen_string_literal: true

require_relative "../test_helper"

class R3InvalidateTest < Minitest::Test
  def test_invalidate_preserves_upstream_and_resets_impacted_nodes
    storage = DAG::Adapters::Memory::Storage.new
    event_bus = DAG::Adapters::Memory::EventBus.new
    workflow_id = create_committed_workflow(storage, chain_definition)
    service = build_mutation_service(storage: storage, event_bus: event_bus)

    result = service.apply(
      workflow_id: workflow_id,
      mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :b],
      expected_revision: 1
    )

    assert_equal 2, result.definition.revision
    assert_equal [:b, :c, :d], result.invalidated_node_ids

    states = storage.load_node_states(workflow_id: workflow_id, revision: 2)
    assert_equal :committed, states[:a]
    assert_equal :pending, states[:b]
    assert_equal :pending, states[:c]
    assert_equal :pending, states[:d]

    stored_event = storage.read_events(workflow_id: workflow_id).last
    assert_equal :mutation_applied, stored_event.type
    assert_equal 2, stored_event.revision
    assert_equal [:b, :c, :d], stored_event.payload[:invalidated_node_ids]
    assert_equal stored_event, event_bus.events.last
  end

  private

  def chain_definition
    DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_node(:c, type: :passthrough)
      .add_node(:d, type: :passthrough)
      .add_edge(:a, :b)
      .add_edge(:b, :c)
      .add_edge(:c, :d)
  end

  def create_committed_workflow(storage, definition)
    workflow_id = create_workflow(storage, definition)
    definition.topological_order.each do |node_id|
      commit_node(storage, workflow_id, definition.revision, node_id)
    end
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)
    workflow_id
  end

  def commit_node(storage, workflow_id, revision, node_id)
    attempt_id = storage.begin_attempt(
      workflow_id: workflow_id,
      revision: revision,
      node_id: node_id,
      expected_node_state: :pending
    )
    storage.commit_attempt(
      attempt_id: attempt_id,
      result: DAG::Success[value: node_id, context_patch: {node_id => true}],
      node_state: :committed,
      event: DAG::Event[
        type: :node_committed,
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: 0,
        payload: {}
      ]
    )
  end

  def build_mutation_service(storage:, event_bus:)
    DAG::MutationService.new(
      storage: storage,
      event_bus: event_bus,
      clock: DAG::Adapters::Stdlib::Clock.new
    )
  end
end
