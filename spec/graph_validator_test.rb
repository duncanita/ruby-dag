# frozen_string_literal: true

require_relative "test_helper"

class GraphValidatorTest < Minitest::Test
  # --- Valid graphs ---

  def test_valid_graph_passes
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    result = DAG::Graph::Validator.validate(graph)
    assert result.valid?
    assert_empty result.errors
  end

  def test_empty_graph_is_valid
    result = DAG::Graph::Validator.validate(DAG::Graph.new)
    assert result.valid?
  end

  # --- Disconnected node detection ---

  def test_detects_disconnected_nodes
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    result = DAG::Graph::Validator.validate(graph)
    refute result.valid?
    assert result.errors.any? { |e| e.include?("disconnected") && e.include?("c") }
  end

  def test_single_node_graph_is_valid
    graph = build_graph([:only], [])
    result = DAG::Graph::Validator.validate(graph)
    assert result.valid?
  end

  # --- Custom validation rules ---

  def test_custom_rule
    graph = build_graph([:a, :b], [[:a, :b]])

    result = DAG::Graph::Validator.validate(graph) do |v|
      v.rule("must have at least 3 nodes") { |g| g.size >= 3 }
    end

    refute result.valid?
    assert_includes result.errors, "must have at least 3 nodes"
  end

  def test_passing_custom_rule
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])

    result = DAG::Graph::Validator.validate(graph) do |v|
      v.rule("must have at least 3 nodes") { |g| g.size >= 3 }
    end

    assert result.valid?
  end

  def test_multiple_errors_collected
    graph = build_graph([:a, :b, :c], [[:a, :b]])

    result = DAG::Graph::Validator.validate(graph) do |v|
      v.rule("must have exactly 2 nodes") { |g| g.size == 2 }
    end

    assert result.errors.size >= 2  # disconnected + custom rule
  end

  # --- Result object ---

  def test_result_has_errors_list
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    result = DAG::Graph::Validator.validate(graph)
    assert_kind_of Array, result.errors
  end

  private

  def build_graph(nodes, edges)
    g = nodes.reduce(DAG::Graph.new) { |graph, n| graph.add_node(n) }
    edges.each { |from, to| g.add_edge(from, to) }
    g
  end
end
