# frozen_string_literal: true

require_relative "../test_helper"

class R3ReplaceSubtreePreservesParallelTest < Minitest::Test
  def test_replace_subtree_preserves_parallel_branch_and_resets_join
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_committed_workflow(storage, diamond_definition)
    service = DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Memory::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )

    result = service.apply(
      workflow_id: workflow_id,
      mutation: DAG::ProposedMutation[
        kind: :replace_subtree,
        target_node_id: :b,
        replacement_graph: DAG::ReplacementGraph[
          graph: DAG::Graph.new.add_node(:b_prime).freeze,
          entry_node_ids: [:b_prime],
          exit_node_ids: [:b_prime]
        ]
      ],
      expected_revision: 1
    )

    definition = result.definition
    refute definition.has_node?(:b)
    assert definition.has_node?(:b_prime)
    assert definition.graph.edge?(:a, :c)
    assert definition.graph.edge?(:c, :d)
    assert definition.graph.edge?(:a, :b_prime)
    assert definition.graph.edge?(:b_prime, :d)
    assert_equal :noop, definition.step_type_for(:b_prime)[:type]
    assert_equal [:d], result.invalidated_node_ids

    states = storage.load_node_states(workflow_id: workflow_id, revision: 2)
    assert_equal :committed, states[:a]
    assert_equal :committed, states[:c]
    assert_equal :pending, states[:b_prime]
    assert_equal :pending, states[:d]
    refute_includes states.keys, :b
  end

  private

  def diamond_definition
    DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_node(:c, type: :passthrough)
      .add_node(:d, type: :passthrough)
      .add_edge(:a, :b)
      .add_edge(:a, :c)
      .add_edge(:b, :d)
      .add_edge(:c, :d)
  end
end
