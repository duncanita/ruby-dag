# frozen_string_literal: true

require_relative "test_helper"

class GraphTest < Minitest::Test
  # --- Building graphs ---

  def test_add_nodes
    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    assert_equal 2, graph.size
    assert graph.node?(:a)
    assert graph.node?(:b)
  end

  def test_add_edge
    graph = build_graph([:a, :b], [[:a, :b]])
    assert graph.edge?(:a, :b)
    refute graph.edge?(:b, :a)
  end

  def test_rejects_duplicate_node
    assert_raises(ArgumentError) do
      DAG::Graph.new.add_node(:a).add_node(:a)
    end
  end

  def test_rejects_edge_to_unknown_node
    assert_raises(ArgumentError) do
      DAG::Graph.new.add_node(:a).add_edge(:a, :missing)
    end
  end

  def test_rejects_edge_from_unknown_node
    assert_raises(ArgumentError) do
      DAG::Graph.new.add_node(:a).add_edge(:missing, :a)
    end
  end

  def test_rejects_self_referencing_edge
    assert_raises(ArgumentError) do
      DAG::Graph.new.add_node(:a).add_edge(:a, :a)
    end
  end

  def test_duplicate_edge_is_idempotent
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.add_edge(:a, :b)
    assert_equal 1, graph.edges.size
  end

  # --- Cycle detection on add_edge ---

  def test_detects_two_node_cycle
    assert_raises(DAG::CycleError) do
      graph = DAG::Graph.new.add_node(:a).add_node(:b)
      graph.add_edge(:a, :b)
      graph.add_edge(:b, :a)
    end
  end

  def test_detects_three_node_cycle
    assert_raises(DAG::CycleError) do
      graph = DAG::Graph.new.add_node(:a).add_node(:b).add_node(:c)
      graph.add_edge(:a, :b)
      graph.add_edge(:b, :c)
      graph.add_edge(:c, :a)
    end
  end

  def test_allows_diamond_shape
    graph = DAG::Graph.new.add_node(:a).add_node(:b).add_node(:c).add_node(:d)
    graph.add_edge(:a, :b)
    graph.add_edge(:a, :c)
    graph.add_edge(:b, :d)
    graph.add_edge(:c, :d)
    assert_equal 4, graph.edges.size
  end

  # --- Topological sort ---

  def test_linear_chain
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    assert_equal [[:a], [:b], [:c]], graph.topological_sort
  end

  def test_independent_nodes_in_same_layer
    graph = build_graph([:a, :b, :c], [[:a, :c], [:b, :c]])
    order = graph.topological_sort
    assert_equal [:a, :b], order[0]
    assert_equal [:c], order[1]
  end

  def test_diamond_dependency
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:a, :c], [:b, :d], [:c, :d]])
    order = graph.topological_sort
    assert_equal [:a], order[0]
    assert_equal [:b, :c], order[1]
    assert_equal [:d], order[2]
  end

  def test_single_node
    graph = build_graph([:only], [])
    assert_equal [[:only]], graph.topological_sort
  end

  def test_large_fan_out
    nodes = [:root] + (1..5).map { |i| :"leaf_#{i}" }
    edges = (1..5).map { |i| [:root, :"leaf_#{i}"] }
    graph = build_graph(nodes, edges)

    order = graph.topological_sort
    assert_equal [:root], order[0]
    assert_equal (1..5).map { |i| :"leaf_#{i}" }.sort, order[1]
  end

  def test_empty_graph_sort
    assert_equal [], DAG::Graph.new.topological_sort
  end

  # --- Graph queries ---

  def test_roots
    graph = build_graph([:a, :b, :c], [[:a, :c], [:b, :c]])
    assert_equal [:a, :b].to_set, graph.roots.to_set
  end

  def test_leaves
    graph = build_graph([:a, :b, :c], [[:a, :b], [:a, :c]])
    assert_equal [:b, :c].to_set, graph.leaves.to_set
  end

  def test_successors
    graph = build_graph([:a, :b, :c], [[:a, :b], [:a, :c]])
    assert_equal [:b, :c].to_set, graph.successors(:a)
  end

  def test_predecessors
    graph = build_graph([:a, :b, :c], [[:a, :c], [:b, :c]])
    assert_equal [:a, :b].to_set, graph.predecessors(:c)
  end

  def test_ancestors
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:b, :c], [:b, :d]])
    assert_equal [:a, :b].to_set, graph.ancestors(:c)
  end

  def test_descendants
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:b, :c], [:b, :d]])
    assert_equal [:b, :c, :d].to_set, graph.descendants(:a)
  end

  def test_ancestors_of_root_is_empty
    graph = build_graph([:a, :b], [[:a, :b]])
    assert_empty graph.ancestors(:a)
  end

  def test_descendants_of_leaf_is_empty
    graph = build_graph([:a, :b], [[:a, :b]])
    assert_empty graph.descendants(:b)
  end

  # --- Subgraph ---

  def test_subgraph_keeps_only_specified_nodes
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:b, :c], [:c, :d]])
    sub = graph.subgraph([:b, :c])

    assert_equal 2, sub.size
    assert sub.edge?(:b, :c)
    refute sub.node?(:a)
    refute sub.node?(:d)
  end

  def test_subgraph_drops_cross_boundary_edges
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    sub = graph.subgraph([:a, :c])

    assert_equal 2, sub.size
    assert_equal 0, sub.edges.size
  end

  def test_subgraph_rejects_unknown_nodes
    graph = build_graph([:a], [])
    assert_raises(ArgumentError) { graph.subgraph([:a, :missing]) }
  end

  # --- Edge data type ---

  def test_edge_is_frozen
    edge = DAG::Edge.new(from: :a, to: :b)
    assert edge.frozen?
    assert_equal :a, edge.from
    assert_equal :b, edge.to
  end

  # --- Empty graph ---

  def test_empty_graph
    graph = DAG::Graph.new
    assert graph.empty?
    assert_equal 0, graph.size
  end

  private

  def build_graph(nodes, edges)
    g = nodes.reduce(DAG::Graph.new) { |graph, n| graph.add_node(n) }
    edges.each { |from, to| g.add_edge(from, to) }
    g
  end
end
