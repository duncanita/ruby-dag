# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/dag"

class RunnerTest < Minitest::Test
  def test_runs_simple_workflow
    graph = DAG::Graph.new
      .add_node(name: :hello, type: :exec, command: "echo hello")

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.success?
    assert_equal "hello", result.value[:hello].value
  end

  def test_passes_output_to_dependent_node
    graph = DAG::Graph.new
      .add_node(name: :produce, type: :exec, command: "echo 42")
      .add_node(name: :consume, type: :ruby, depends_on: [:produce],
                callable: ->(input) { DAG::Result.success("got: #{input}") })

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.success?
    assert_equal "got: 42", result.value[:consume].value
  end

  def test_stops_on_failure
    graph = DAG::Graph.new
      .add_node(name: :fail_node, type: :exec, command: "exit 1")
      .add_node(name: :never_runs, type: :exec, command: "echo nope", depends_on: [:fail_node])

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.failure?
    assert_equal :fail_node, result.error[:failed_node]
    refute result.error[:outputs].key?(:never_runs)
  end

  def test_runs_parallel_nodes_sequentially_when_disabled
    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :exec, command: "echo b")

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.success?
    assert_equal "a", result.value[:a].value
    assert_equal "b", result.value[:b].value
  end

  def test_file_read_node
    tmpfile = "/tmp/dag_test_#{$$}.txt"
    File.write(tmpfile, "test content")

    graph = DAG::Graph.new
      .add_node(name: :read, type: :file_read, path: tmpfile)

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.success?
    assert_equal "test content", result.value[:read].value
  ensure
    File.delete(tmpfile) if File.exist?(tmpfile)
  end

  def test_file_write_node
    tmpfile = "/tmp/dag_test_write_#{$$}.txt"

    graph = DAG::Graph.new
      .add_node(name: :write, type: :file_write, path: tmpfile, content: "written by dag")

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.success?
    assert_equal "written by dag", File.read(tmpfile)
  ensure
    File.delete(tmpfile) if File.exist?(tmpfile)
  end

  def test_ruby_node_with_callable
    graph = DAG::Graph.new
      .add_node(name: :compute, type: :ruby,
                callable: ->(_input) { DAG::Result.success(6 * 7) })

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.success?
    assert_equal 42, result.value[:compute].value
  end

  def test_callbacks_are_called
    started = []
    finished = []

    graph = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :exec, command: "echo b", depends_on: [:a])

    DAG::Runner.new(graph, parallel: false,
      on_node_start: ->(name, _node) { started << name },
      on_node_finish: ->(name, _result) { finished << name }
    ).call

    assert_equal [:a, :b], started
    assert_equal [:a, :b], finished
  end

  def test_merges_multiple_dependency_outputs
    graph = DAG::Graph.new
      .add_node(name: :x, type: :exec, command: "echo X")
      .add_node(name: :y, type: :exec, command: "echo Y")
      .add_node(name: :merge, type: :ruby, depends_on: [:x, :y],
                callable: ->(input) { DAG::Result.success(input.values.sort.join("+")) })

    result = DAG::Runner.new(graph, parallel: false).call
    assert result.success?
    assert_equal "X+Y", result.value[:merge].value
  end
end
