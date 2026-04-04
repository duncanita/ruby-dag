# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/dag"

class LoaderTest < Minitest::Test
  def test_loads_simple_yaml
    yaml = <<~YAML
      name: test
      nodes:
        greet:
          type: exec
          command: "echo hello"
    YAML

    graph = DAG::Loader.from_yaml(yaml)
    assert_equal 1, graph.size
    assert_equal :exec, graph.node(:greet).type
  end

  def test_loads_dependencies
    yaml = <<~YAML
      name: test
      nodes:
        first:
          type: exec
          command: "echo 1"
        second:
          type: exec
          command: "echo 2"
          depends_on:
            - first
    YAML

    graph = DAG::Loader.from_yaml(yaml)
    assert_equal [[:first], [:second]], graph.execution_order
  end

  def test_rejects_missing_type
    yaml = <<~YAML
      name: test
      nodes:
        bad:
          command: "echo oops"
    YAML

    assert_raises(ArgumentError) { DAG::Loader.from_yaml(yaml) }
  end

  def test_rejects_invalid_type
    yaml = <<~YAML
      name: test
      nodes:
        bad:
          type: banana
          command: "echo oops"
    YAML

    assert_raises(ArgumentError) { DAG::Loader.from_yaml(yaml) }
  end

  def test_detects_cycle_in_yaml
    yaml = <<~YAML
      name: test
      nodes:
        a:
          type: exec
          command: "echo a"
          depends_on: [b]
        b:
          type: exec
          command: "echo b"
          depends_on: [a]
    YAML

    assert_raises(DAG::CycleError) { DAG::Loader.from_yaml(yaml) }
  end

  def test_loads_from_file
    tmpfile = "/tmp/dag_test_workflow_#{$$}.yml"
    File.write(tmpfile, <<~YAML)
      name: file-test
      nodes:
        only:
          type: exec
          command: "echo from-file"
    YAML

    graph = DAG::Loader.from_file(tmpfile)
    assert_equal 1, graph.size
  ensure
    File.delete(tmpfile) if File.exist?(tmpfile)
  end
end
