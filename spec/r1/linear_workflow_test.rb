# frozen_string_literal: true

require_relative "../test_helper"

class LinearWorkflowTest < Minitest::Test
  def test_passthrough_chain_propagates_context
    storage = DAG::Adapters::Memory::Storage.new
    event_bus = DAG::Adapters::Memory::EventBus.new
    runner = build_runner(storage: storage, event_bus: event_bus)

    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_node(:c, type: :passthrough)
      .add_edge(:a, :b)
      .add_edge(:b, :c)

    workflow_id = create_workflow(storage, definition, initial_context: {x: 1})

    result = runner.call(workflow_id)

    assert_equal :completed, result.state
    attempts = storage.list_attempts(workflow_id: workflow_id, node_id: :c)
    assert_equal({x: 1}, attempts.last[:result].context_patch)
    assert_includes event_bus.events.map(&:type), :workflow_completed
  end

  def test_initial_context_persists_through_storage
    storage = DAG::Adapters::Memory::Storage.new
    runner = build_runner(storage: storage)
    workflow_id = create_workflow(storage, three_node_chain(:a, :b, :c), initial_context: {greeting: "ciao"})

    runner.call(workflow_id)
    attempts = storage.list_attempts(workflow_id: workflow_id, node_id: :a)
    assert_equal({greeting: "ciao"}, attempts.last[:result].context_patch)
  end
end
