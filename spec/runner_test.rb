# frozen_string_literal: true

require_relative "test_helper"

class RunnerTest < Minitest::Test
  include TestHelpers

  # --- Basic execution ---

  def test_runs_single_node
    result = run_workflow({hello: {command: "echo hello"}})
    assert result.success?
    assert_equal "hello", result.value[:hello].value
  end

  def test_passes_output_to_dependent_node
    defn = build_test_workflow(
      produce: {},
      consume: {type: :ruby, depends_on: [:produce],
                callable: ->(input) { DAG::Success("got: #{input}") }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal "got: produce", result.value[:consume].value
  end

  def test_merges_multiple_dependency_outputs
    defn = build_test_workflow(
      x: {command: "echo X"},
      y: {command: "echo Y"},
      merge: {type: :ruby, depends_on: [:x, :y],
              callable: ->(input) { DAG::Success(input.values.sort.join("+")) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal "X+Y", result.value[:merge].value
  end

  # --- Failure handling ---

  def test_stops_on_failure
    defn = build_test_workflow(
      fail_node: {command: "exit 1"},
      never_runs: {depends_on: [:fail_node]}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert result.failure?
    assert_equal :fail_node, result.error[:failed_node]
    refute result.error[:outputs].key?(:never_runs)
  end

  def test_failure_includes_error_detail
    result = run_workflow({bad: {command: "echo fail >&2; exit 42"}})
    assert result.failure?
    assert_match(/Exit 42/, result.error[:error])
  end

  # --- Parallel execution ---

  def test_parallel_independent_nodes
    result = run_workflow(
      {a: {command: "echo a"}, b: {command: "echo b"}},
      parallel: true
    )

    assert result.success?
    assert_equal "a", result.value[:a].value
    assert_equal "b", result.value[:b].value
  end

  def test_sequential_independent_nodes
    result = run_workflow(
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

    defn = build_test_workflow(
      read: {type: :file_read, path: input_path},
      transform: {type: :ruby, depends_on: [:read],
                  callable: ->(input) { DAG::Success(input.upcase) }},
      write: {type: :file_write, path: output_path, depends_on: [:transform]}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call

    assert result.success?
    assert_equal "HELLO WORLD", File.read(output_path)
  ensure
    [input_path, output_path].each { |p| File.delete(p) if File.exist?(p) }
  end

  # --- Callbacks ---

  def test_callbacks_fire_in_order
    started = []
    finished = []

    defn = build_test_workflow(
      a: {},
      b: {depends_on: [:a]}
    )

    DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false,
      on_node_start: ->(name, _step) { started << name },
      on_node_finish: ->(name, _result) { finished << name }).call

    assert_equal [:a, :b], started
    assert_equal [:a, :b], finished
  end

  def test_callbacks_fire_for_parallel_nodes
    finished = []

    defn = build_test_workflow(a: {}, b: {})

    DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true,
      on_node_finish: ->(name, _result) { finished << name }).call

    assert_includes finished, :a
    assert_includes finished, :b
  end

  # --- Edge cases ---

  def test_empty_graph_succeeds
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_equal({}, result.value)
  end

  private

  def run_workflow(node_defs = {}, parallel: false)
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new

    node_defs.each do |name, config|
      graph.add_node(name)
      registry.register(DAG::Workflow::Step.new(name: name, type: :exec, **config))
    end

    DAG::Workflow::Runner.new(graph, registry, parallel: parallel).call
  end
end
