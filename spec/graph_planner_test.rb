# frozen_string_literal: true

require_relative "test_helper"

class GraphPlannerTest < Minitest::Test
  # --- layers ---

  def test_layers_linear
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    planner = DAG::Graph::Planner.new(graph)
    assert_equal [[:a], [:b], [:c]], planner.layers
  end

  def test_layers_diamond
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:a, :c], [:b, :d], [:c, :d]])
    planner = DAG::Graph::Planner.new(graph)
    assert_equal [[:a], [:b, :c], [:d]], planner.layers
  end

  def test_layers_independent_sorted
    graph = build_graph([:c, :b, :a], [])
    planner = DAG::Graph::Planner.new(graph)
    assert_equal [[:a, :b, :c]], planner.layers
  end

  def test_layers_fan_out
    nodes = [:root] + (1..4).map { |i| :"leaf_#{i}" }
    edges = (1..4).map { |i| [:root, :"leaf_#{i}"] }
    graph = build_graph(nodes, edges)
    planner = DAG::Graph::Planner.new(graph)

    assert_equal [:root], planner.layers[0]
    assert_equal (1..4).map { |i| :"leaf_#{i}" }, planner.layers[1]
  end

  def test_layers_fan_in
    graph = build_graph([:a, :b, :c, :d], [[:a, :d], [:b, :d], [:c, :d]])
    planner = DAG::Graph::Planner.new(graph)
    assert_equal [[:a, :b, :c], [:d]], planner.layers
  end

  def test_layers_empty_graph
    planner = DAG::Graph::Planner.new(DAG::Graph.new)
    assert_equal [], planner.layers
  end

  # --- flat_order ---

  def test_flat_order_linear
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    planner = DAG::Graph::Planner.new(graph)
    assert_equal [:a, :b, :c], planner.flat_order
  end

  def test_flat_order_diamond
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:a, :c], [:b, :d], [:c, :d]])
    order = DAG::Graph::Planner.new(graph).flat_order
    assert_equal :a, order.first
    assert_equal :d, order.last
  end

  def test_flat_order_empty
    assert_equal [], DAG::Graph::Planner.new(DAG::Graph.new).flat_order
  end

  # --- each_layer ---

  def test_each_layer_yields_layers
    graph = build_graph([:a, :b, :c], [[:a, :b], [:a, :c]])
    planner = DAG::Graph::Planner.new(graph)
    collected = []
    planner.each_layer { |layer| collected << layer }
    assert_equal [[:a], [:b, :c]], collected
  end

  def test_each_layer_returns_enumerator
    planner = DAG::Graph::Planner.new(DAG::Graph.new)
    assert_instance_of Enumerator, planner.each_layer
  end

  # --- works with frozen graphs ---

  def test_plans_frozen_graph
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    graph.freeze
    planner = DAG::Graph::Planner.new(graph)
    assert_equal [[:a], [:b], [:c]], planner.layers
  end

  private

  def build_graph(nodes, edges)
    g = nodes.reduce(DAG::Graph.new) { |graph, n| graph.add_node(n) }
    edges.each { |from, to| g.add_edge(from, to) }
    g
  end
end
