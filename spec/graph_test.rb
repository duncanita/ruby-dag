# frozen_string_literal: true

require_relative "test_helper"

class GraphTest < Minitest::Test
  # --- Execution order ---

  def test_linear_chain_executes_in_order
    graph = build_graph(
      a: {},
      b: {depends_on: [:a]},
      c: {depends_on: [:b]}
    )

    assert_equal [[:a], [:b], [:c]], graph.execution_order
  end

  def test_independent_nodes_run_in_same_layer
    graph = build_graph(
      a: {},
      b: {},
      c: {depends_on: [:a, :b]}
    )

    order = graph.execution_order
    assert_equal [:a, :b], order[0]
    assert_equal [:c], order[1]
  end

  def test_diamond_dependency
    graph = build_graph(
      a: {},
      b: {depends_on: [:a]},
      c: {depends_on: [:a]},
      d: {depends_on: [:b, :c]}
    )

    order = graph.execution_order
    assert_equal [:a], order[0]
    assert_equal [:b, :c], order[1]
    assert_equal [:d], order[2]
  end

  def test_single_node
    graph = build_graph(only: {})
    assert_equal [[:only]], graph.execution_order
  end

  def test_large_fan_out
    deps = (1..5).map { |i| :"leaf_#{i}" }
    nodes = deps.each_with_object({root: {}}) do |name, h|
      h[name] = {depends_on: [:root]}
    end

    graph = build_graph(**nodes)
    order = graph.execution_order

    assert_equal [:root], order[0]
    assert_equal deps.sort, order[1]
  end

  # --- Validation errors ---

  def test_detects_cycle
    assert_raises(DAG::CycleError) do
      build_graph(
        a: {depends_on: [:b]},
        b: {depends_on: [:a]}
      )
    end
  end

  def test_detects_three_node_cycle
    assert_raises(DAG::CycleError) do
      build_graph(
        a: {depends_on: [:c]},
        b: {depends_on: [:a]},
        c: {depends_on: [:b]}
      )
    end
  end

  def test_detects_self_reference
    assert_raises(DAG::CycleError) do
      build_graph(a: {depends_on: [:a]})
    end
  end

  def test_detects_missing_dependency
    assert_raises(ArgumentError) do
      build_graph(a: {depends_on: [:missing]})
    end
  end

  def test_rejects_duplicate_node
    assert_raises(ArgumentError) do
      DAG::Graph.new
        .add_node(name: :a, type: :exec, command: "echo a")
        .add_node(name: :a, type: :exec, command: "echo b")
    end
  end

  # --- Empty graph ---

  def test_empty_graph
    graph = DAG::Graph.new
    assert graph.empty?
    assert_equal 0, graph.size
  end

  private

  def build_graph(**node_defs)
    node_defs.each_with_object(DAG::Graph.new) do |(name, opts), graph|
      graph.add_node(name: name, type: :exec, command: "echo #{name}", **opts)
    end.tap(&:validate!)
  end
end
