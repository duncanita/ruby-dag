# frozen_string_literal: true

require_relative "test_helper"

class GraphBuilderTest < Minitest::Test
  # --- Basic building ---

  def test_builds_graph_with_nodes_and_edges
    graph = DAG::Graph::Builder.new
      .add_node(:a)
      .add_node(:b)
      .add_edge(:a, :b)
      .build

    assert_instance_of DAG::Graph, graph
    assert graph.node?(:a)
    assert graph.node?(:b)
    assert graph.edge?(:a, :b)
  end

  def test_build_returns_frozen_graph
    graph = DAG::Graph::Builder.new
      .add_node(:a)
      .build

    assert graph.frozen?
  end

  def test_frozen_graph_rejects_mutation
    graph = DAG::Graph::Builder.new
      .add_node(:a)
      .add_node(:b)
      .build

    assert_raises(FrozenError) { graph.add_node(:c) }
    assert_raises(FrozenError) { graph.add_edge(:a, :b) }
  end

  # --- Validation errors during build ---

  def test_rejects_duplicate_node
    assert_raises(DAG::DuplicateNodeError) do
      DAG::Graph::Builder.new
        .add_node(:a)
        .add_node(:a)
    end
  end

  def test_rejects_self_edge
    assert_raises(ArgumentError) do
      DAG::Graph::Builder.new
        .add_node(:a)
        .add_edge(:a, :a)
    end
  end

  def test_rejects_cycle
    assert_raises(DAG::CycleError) do
      DAG::Graph::Builder.new
        .add_node(:a)
        .add_node(:b)
        .add_edge(:a, :b)
        .add_edge(:b, :a)
    end
  end

  def test_rejects_unknown_edge_node
    assert_raises(DAG::UnknownNodeError) do
      DAG::Graph::Builder.new
        .add_node(:a)
        .add_edge(:a, :missing)
    end
  end

  # --- Block form ---

  def test_block_form
    graph = DAG::Graph::Builder.build do |b|
      b.add_node(:x)
      b.add_node(:y)
      b.add_edge(:x, :y)
    end

    assert graph.frozen?
    assert graph.edge?(:x, :y)
  end

  # --- Built graph is fully functional ---

  def test_built_graph_supports_queries
    graph = DAG::Graph::Builder.build do |b|
      b.add_node(:a)
      b.add_node(:b)
      b.add_node(:c)
      b.add_edge(:a, :b)
      b.add_edge(:b, :c)
    end

    assert_equal [[:a], [:b], [:c]], graph.topological_layers
    assert_equal [:a, :b, :c], graph.topological_sort
    assert graph.path?(:a, :c)
    assert_equal 3, graph.size
  end

  # --- Empty graph ---

  def test_empty_graph
    graph = DAG::Graph::Builder.new.build
    assert graph.frozen?
    assert graph.empty?
  end
end
