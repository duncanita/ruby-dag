# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/dag"

class GraphTest < Minitest::Test
  def test_linear_execution_order
    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :exec, command: "echo b", depends_on: [:a])
      .add_node(name: :c, type: :exec, command: "echo c", depends_on: [:b])

    assert_equal [[:a], [:b], [:c]], graph.execution_order
  end

  def test_parallel_nodes_in_same_layer
    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :exec, command: "echo b")
      .add_node(name: :c, type: :exec, command: "echo c", depends_on: [:a, :b])

    order = graph.execution_order
    assert_equal [:a, :b], order[0]
    assert_equal [:c], order[1]
  end

  def test_detects_cycle
    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a", depends_on: [:b])
      .add_node(name: :b, type: :exec, command: "echo b", depends_on: [:a])

    assert_raises(DAG::CycleError) { graph.validate! }
  end

  def test_detects_missing_dependency
    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a", depends_on: [:missing])

    assert_raises(ArgumentError) { graph.validate! }
  end

  def test_rejects_duplicate_node
    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")

    assert_raises(ArgumentError) { graph.add_node(name: :a, type: :exec, command: "echo b") }
  end

  def test_diamond_dependency
    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :exec, command: "echo b", depends_on: [:a])
      .add_node(name: :c, type: :exec, command: "echo c", depends_on: [:a])
      .add_node(name: :d, type: :exec, command: "echo d", depends_on: [:b, :c])

    order = graph.execution_order
    assert_equal [:a], order[0]
    assert_equal [:b, :c], order[1]
    assert_equal [:d], order[2]
  end

  def test_single_node_graph
    graph = DAG::Graph.new
      .add_node(name: :only, type: :exec, command: "echo only")

    assert_equal [[:only]], graph.execution_order
  end
end
