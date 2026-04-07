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

  # --- Disconnected node detection (on by default) ---

  def test_detects_isolated_nodes_by_default
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    result = DAG::Graph::Validator.validate(graph)
    refute result.valid?
    assert result.errors.any? { |e| e.include?("isolated") && e.include?("c") }
  end

  def test_isolated_nodes_can_be_opted_out
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    result = DAG::Graph::Validator.validate(graph, defaults: [])
    assert result.valid?
  end

  def test_single_node_graph_is_valid
    graph = build_graph([:only], [])
    result = DAG::Graph::Validator.validate(graph)
    assert result.valid?
  end

  def test_custom_rule_runs_alongside_defaults
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    result = DAG::Graph::Validator.validate(graph) do |v|
      v.rule("must have edge a->c") { |g| g.edge?(:a, :c) }
    end
    refute result.valid?
    assert_equal ["must have edge a->c"], result.errors
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

    assert result.errors.size >= 2  # isolated + custom rule
  end

  # --- validate! raises ---

  def test_validate_bang_returns_graph_when_valid
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    assert_same graph, DAG::Graph::Validator.validate!(graph)
  end

  def test_validate_bang_raises_on_invalid
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    error = assert_raises(DAG::ValidationError) do
      DAG::Graph::Validator.validate!(graph)
    end
    assert error.message.include?("isolated")
    assert_kind_of Array, error.errors
  end

  def test_validate_bang_raises_on_custom_rule_failure
    graph = build_graph([:a, :b], [[:a, :b]])
    assert_raises(DAG::ValidationError) do
      DAG::Graph::Validator.validate!(graph) do |v|
        v.rule("too small") { |g| g.size >= 10 }
      end
    end
  end

  # --- Result object ---

  def test_result_has_errors_list
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    result = DAG::Graph::Validator.validate(graph)
    assert_kind_of Array, result.errors
  end

  def test_report_errors_are_frozen
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    report = DAG::Graph::Validator.validate(graph)
    assert report.errors.frozen?
    assert_raises(FrozenError) { report.errors << "injected" }
  end

  # Freeze invariant lives on the Report type, not the call site: a Report
  # constructed directly from a mutable Array must still expose a frozen one.
  def test_report_freezes_errors_passed_directly_to_constructor
    report = DAG::Graph::Report.new(errors: ["raw"])
    assert report.errors.frozen?
  end

  private

  def build_graph(nodes, edges)
    g = nodes.reduce(DAG::Graph.new) { |graph, n| graph.add_node(n) }
    edges.each { |from, to| g.add_edge(from, to) }
    g
  end
end
