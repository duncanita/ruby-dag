# frozen_string_literal: true

require_relative "test_helper"

class RunnerTest < Minitest::Test
  # --- Basic execution ---

  def test_runs_single_node
    result = run_graph({hello: {command: "echo hello"}})
    assert result.success?
    assert_equal "hello", result.value[:hello].value
  end

  def test_passes_output_to_dependent_node
    graph = DAG::Graph.new
      .add_node(name: :produce, type: :exec, command: "echo 42")
      .add_node(name: :consume, type: :ruby, depends_on: [:produce],
        callable: ->(input) { DAG::Success("got: #{input}") })

    result = DAG::Runner.new(graph, parallel: false).call
    assert_equal "got: 42", result.value[:consume].value
  end

  def test_merges_multiple_dependency_outputs
    graph = DAG::Graph.new
      .add_node(name: :x, type: :exec, command: "echo X")
      .add_node(name: :y, type: :exec, command: "echo Y")
      .add_node(name: :merge, type: :ruby, depends_on: [:x, :y],
        callable: ->(input) { DAG::Success(input.values.sort.join("+")) })

    result = DAG::Runner.new(graph, parallel: false).call
    assert_equal "X+Y", result.value[:merge].value
  end

  # --- Failure handling ---

  def test_stops_on_failure
    graph = DAG::Graph.new
      .add_node(name: :fail_node, type: :exec, command: "exit 1")
      .add_node(name: :never_runs, type: :exec, command: "echo nope", depends_on: [:fail_node])

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.failure?
    assert_equal :fail_node, result.error[:failed_node]
    refute result.error[:outputs].key?(:never_runs)
  end

  def test_failure_includes_error_detail
    result = run_graph({bad: {command: "echo fail >&2; exit 42"}})
    assert result.failure?
    assert_match(/Exit 42/, result.error[:error])
  end

  # --- Parallel execution ---

  def test_parallel_independent_nodes
    result = run_graph(
      {a: {command: "echo a"}, b: {command: "echo b"}},
      parallel: true
    )

    assert result.success?
    assert_equal "a", result.value[:a].value
    assert_equal "b", result.value[:b].value
  end

  def test_sequential_independent_nodes
    result = run_graph(
      {a: {command: "echo a"}, b: {command: "echo b"}},
      parallel: false
    )

    assert result.success?
    assert_equal "a", result.value[:a].value
    assert_equal "b", result.value[:b].value
  end

  # --- File pipeline ---

  def test_read_transform_write_pipeline
    input_path = "/tmp/dag_test_in_#{$$}.txt"
    output_path = "/tmp/dag_test_out_#{$$}.txt"
    File.write(input_path, "hello world")

    graph = DAG::Graph.new
      .add_node(name: :read, type: :file_read, path: input_path)
      .add_node(name: :transform, type: :ruby, depends_on: [:read],
        callable: ->(input) { DAG::Success(input.upcase) })
      .add_node(name: :write, type: :file_write, path: output_path, depends_on: [:transform])

    result = DAG::Runner.new(graph, parallel: false).call

    assert result.success?
    assert_equal "HELLO WORLD", File.read(output_path)
  ensure
    [input_path, output_path].each { |p| File.delete(p) if File.exist?(p) }
  end

  # --- Callbacks ---

  def test_callbacks_fire_in_order
    started = []
    finished = []

    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :exec, command: "echo b", depends_on: [:a])

    DAG::Runner.new(graph, parallel: false,
      on_node_start: ->(name, _node) { started << name },
      on_node_finish: ->(name, _result) { finished << name }).call

    assert_equal [:a, :b], started
    assert_equal [:a, :b], finished
  end

  def test_callbacks_fire_for_parallel_nodes
    finished = []

    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :exec, command: "echo b")

    DAG::Runner.new(graph, parallel: true,
      on_node_finish: ->(name, _result) { finished << name }).call

    assert_includes finished, :a
    assert_includes finished, :b
  end

  # --- Edge cases ---

  def test_empty_graph_succeeds
    result = DAG::Runner.new(DAG::Graph.new, parallel: false).call
    assert result.success?
    assert_equal({}, result.value)
  end

  private

  def run_graph(node_defs = {}, parallel: false)
    graph = node_defs.each_with_object(DAG::Graph.new) do |(name, config), g|
      g.add_node(name: name, type: :exec, **config)
    end

    DAG::Runner.new(graph, parallel: parallel).call
  end
end
