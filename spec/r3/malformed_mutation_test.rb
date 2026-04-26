# frozen_string_literal: true

require_relative "../test_helper"

class R3MalformedMutationTest < Minitest::Test
  def test_plan_returns_invalid_when_mutation_is_not_a_proposed_mutation
    plan = DAG::DefinitionEditor.new.plan(simple_definition, Object.new)

    refute plan.valid?
    assert_match(/mutation must be a DAG::ProposedMutation/, plan.reason)
  end

  def test_proposed_mutation_new_rejects_non_replacement_graph
    error = assert_raises(ArgumentError) do
      DAG::ProposedMutation.new(
        kind: :replace_subtree,
        target_node_id: :a,
        replacement_graph: Object.new
      )
    end

    assert_match(/replace_subtree requires replacement_graph/, error.message)
  end

  def test_proposed_mutation_new_rejects_nil_replacement_graph
    error = assert_raises(ArgumentError) do
      DAG::ProposedMutation.new(kind: :replace_subtree, target_node_id: :a, replacement_graph: nil)
    end

    assert_match(/replace_subtree requires replacement_graph/, error.message)
  end

  def test_replacement_graph_new_rejects_nil_inner_graph
    assert_replacement_graph_error(/graph must be a DAG::Graph/) do
      DAG::ReplacementGraph.new(graph: nil, entry_node_ids: [:x], exit_node_ids: [:x])
    end
  end

  def test_replacement_graph_new_rejects_non_graph_inner_graph
    assert_replacement_graph_error(/graph must be a DAG::Graph/) do
      DAG::ReplacementGraph.new(graph: "not a graph", entry_node_ids: [:x], exit_node_ids: [:x])
    end
  end

  def test_replacement_graph_new_rejects_empty_entry_node_ids
    assert_replacement_graph_error(/entry_node_ids cannot be empty/) do
      DAG::ReplacementGraph.new(
        graph: DAG::Graph.new.add_node(:x).freeze,
        entry_node_ids: [],
        exit_node_ids: [:x]
      )
    end
  end

  def test_replacement_graph_new_rejects_empty_exit_node_ids
    assert_replacement_graph_error(/exit_node_ids cannot be empty/) do
      DAG::ReplacementGraph.new(
        graph: DAG::Graph.new.add_node(:x).freeze,
        entry_node_ids: [:x],
        exit_node_ids: []
      )
    end
  end

  def test_replacement_graph_new_rejects_entry_node_not_in_graph
    assert_replacement_graph_error(/entry node not in graph/) do
      DAG::ReplacementGraph.new(
        graph: DAG::Graph.new.add_node(:x).freeze,
        entry_node_ids: [:not_in_graph],
        exit_node_ids: [:x]
      )
    end
  end

  def test_replacement_graph_new_rejects_exit_node_not_in_graph
    assert_replacement_graph_error(/exit node not in graph/) do
      DAG::ReplacementGraph.new(
        graph: DAG::Graph.new.add_node(:x).freeze,
        entry_node_ids: [:x],
        exit_node_ids: [:not_in_graph]
      )
    end
  end

  def test_replacement_graph_new_rejects_non_array_entry_node_ids
    assert_replacement_graph_error(/entry_node_ids must be an Array/) do
      DAG::ReplacementGraph.new(
        graph: DAG::Graph.new.add_node(:x).freeze,
        entry_node_ids: 42,
        exit_node_ids: [:x]
      )
    end
  end

  def test_replacement_graph_new_rejects_non_symbolic_entry_node_ids
    assert_replacement_graph_error(/entry_node_ids entries must be Symbol or String/) do
      DAG::ReplacementGraph.new(
        graph: DAG::Graph.new.add_node(:x).freeze,
        entry_node_ids: [42],
        exit_node_ids: [:x]
      )
    end
  end

  def test_replacement_graph_new_rejects_nil_entry_node_ids
    assert_replacement_graph_error(/entry_node_ids entries must be Symbol or String/) do
      DAG::ReplacementGraph.new(
        graph: DAG::Graph.new.add_node(:x).freeze,
        entry_node_ids: [nil],
        exit_node_ids: [:x]
      )
    end
  end

  private

  def assert_replacement_graph_error(pattern)
    error = assert_raises(ArgumentError) { yield }
    assert_match pattern, error.message
  end
end
