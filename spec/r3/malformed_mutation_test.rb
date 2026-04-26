# frozen_string_literal: true

require_relative "../test_helper"

class R3MalformedMutationTest < Minitest::Test
  def test_plan_returns_invalid_when_replacement_graph_is_not_a_replacement_graph
    plan = plan_replace(replacement_graph: Object.new)
    assert_invalid plan, /replacement_graph must be a DAG::ReplacementGraph/
  end

  def test_plan_returns_invalid_when_replacement_graph_is_nil
    plan = plan_replace(replacement_graph: nil)
    assert_invalid plan, /replacement_graph must be a DAG::ReplacementGraph/
  end

  def test_plan_returns_invalid_when_replacement_inner_graph_is_nil
    bad = DAG::ReplacementGraph.new(graph: nil, entry_node_ids: [:x], exit_node_ids: [:x])
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /replacement graph must be a DAG::Graph/
  end

  def test_plan_returns_invalid_when_replacement_inner_graph_is_not_a_graph
    bad = DAG::ReplacementGraph.new(graph: "not a graph", entry_node_ids: [:x], exit_node_ids: [:x])
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /replacement graph must be a DAG::Graph/
  end

  def test_plan_returns_invalid_when_entry_node_ids_empty
    bad = DAG::ReplacementGraph.new(
      graph: DAG::Graph.new.add_node(:x).freeze,
      entry_node_ids: [],
      exit_node_ids: [:x]
    )
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /entry_node_ids cannot be empty/
  end

  def test_plan_returns_invalid_when_exit_node_ids_empty
    bad = DAG::ReplacementGraph.new(
      graph: DAG::Graph.new.add_node(:x).freeze,
      entry_node_ids: [:x],
      exit_node_ids: []
    )
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /exit_node_ids cannot be empty/
  end

  def test_plan_returns_invalid_when_entry_node_not_in_graph
    bad = DAG::ReplacementGraph.new(
      graph: DAG::Graph.new.add_node(:x).freeze,
      entry_node_ids: [:not_in_graph],
      exit_node_ids: [:x]
    )
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /replacement entry node is not in graph/
  end

  def test_plan_returns_invalid_when_exit_node_not_in_graph
    bad = DAG::ReplacementGraph.new(
      graph: DAG::Graph.new.add_node(:x).freeze,
      entry_node_ids: [:x],
      exit_node_ids: [:not_in_graph]
    )
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /replacement exit node is not in graph/
  end

  def test_plan_returns_invalid_when_entry_node_ids_not_an_array
    bad = DAG::ReplacementGraph.new(
      graph: DAG::Graph.new.add_node(:x).freeze,
      entry_node_ids: 42,
      exit_node_ids: [:x]
    )
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /entry_node_ids must be an Array/
  end

  def test_plan_returns_invalid_when_entry_node_ids_contains_non_symbolic
    bad = DAG::ReplacementGraph.new(
      graph: DAG::Graph.new.add_node(:x).freeze,
      entry_node_ids: [42],
      exit_node_ids: [:x]
    )
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /entry_node_ids entries must be Symbol or String/
  end

  def test_plan_returns_invalid_when_entry_node_ids_contains_nil
    bad = DAG::ReplacementGraph.new(
      graph: DAG::Graph.new.add_node(:x).freeze,
      entry_node_ids: [nil],
      exit_node_ids: [:x]
    )
    plan = plan_replace(replacement_graph: bad)
    assert_invalid plan, /entry_node_ids entries must be Symbol or String/
  end

  def test_replacement_graph_factory_rejects_non_array_entry_node_ids
    graph = DAG::Graph.new.add_node(:x).freeze

    error = assert_raises(ArgumentError) do
      DAG::ReplacementGraph[graph: graph, entry_node_ids: 42, exit_node_ids: [:x]]
    end

    assert_match(/entry_node_ids must be an Array/, error.message)
  end

  def test_replacement_graph_factory_rejects_non_symbolic_entry_node_ids
    graph = DAG::Graph.new.add_node(:x).freeze

    error = assert_raises(ArgumentError) do
      DAG::ReplacementGraph[graph: graph, entry_node_ids: [nil], exit_node_ids: [:x]]
    end

    assert_match(/entry_node_ids entries must be Symbol or String/, error.message)
  end

  private

  def plan_replace(replacement_graph:)
    mutation = DAG::ProposedMutation.new(
      kind: :replace_subtree,
      target_node_id: :a,
      replacement_graph: replacement_graph,
      rationale: nil,
      confidence: 1.0,
      metadata: {}
    )
    DAG::DefinitionEditor.new.plan(simple_definition, mutation)
  end

  def assert_invalid(plan, reason_pattern)
    refute plan.valid?
    assert_match reason_pattern, plan.reason
  end
end
