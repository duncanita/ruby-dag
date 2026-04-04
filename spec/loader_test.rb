# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/dag"

class LoaderTest < Minitest::Test
  def test_loads_simple_workflow
    graph = load_yaml(<<~YAML)
      name: test
      nodes:
        greet:
          type: exec
          command: "echo hello"
    YAML

    assert_equal 1, graph.size
    assert_equal :exec, graph.node(:greet).type
  end

  def test_loads_dependencies
    graph = load_yaml(<<~YAML)
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

    assert_equal [[:first], [:second]], graph.execution_order
  end

  def test_loads_all_node_types
    graph = load_yaml(<<~YAML)
      name: test
      nodes:
        a:
          type: exec
          command: "echo a"
        b:
          type: file_read
          path: "/tmp/test.txt"
        c:
          type: file_write
          path: "/tmp/out.txt"
          depends_on: [b]
        d:
          type: llm
          prompt: "test"
          command: "echo test"
          depends_on: [a]
    YAML

    assert_equal 4, graph.size
  end

  def test_passes_extra_config_through
    graph = load_yaml(<<~YAML)
      name: test
      nodes:
        task:
          type: exec
          command: "echo x"
          timeout: 60
          custom_key: "custom_value"
    YAML

    assert_equal 60, graph.node(:task).config[:timeout]
    assert_equal "custom_value", graph.node(:task).config[:custom_key]
  end

  def test_loads_from_file
    file = Tempfile.new(["workflow", ".yml"])
    file.write(<<~YAML)
      name: file-test
      nodes:
        only:
          type: exec
          command: "echo from-file"
    YAML
    file.close

    graph = DAG::Loader.from_file(file.path)
    assert_equal 1, graph.size
  ensure
    file&.unlink
  end

  # --- Error handling ---

  def test_rejects_missing_nodes_key
    assert_raises(ArgumentError) { load_yaml("name: test") }
  end

  def test_rejects_missing_type
    assert_raises(ArgumentError) do
      load_yaml(<<~YAML)
        name: test
        nodes:
          bad:
            command: "echo oops"
      YAML
    end
  end

  def test_rejects_invalid_type
    assert_raises(ArgumentError) do
      load_yaml(<<~YAML)
        name: test
        nodes:
          bad:
            type: banana
            command: "echo oops"
      YAML
    end
  end

  def test_detects_cycle_in_yaml
    assert_raises(DAG::CycleError) do
      load_yaml(<<~YAML)
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
    end
  end

  def test_rejects_missing_file
    assert_raises(ArgumentError) { DAG::Loader.from_file("/nonexistent.yml") }
  end

  private

  def load_yaml(yaml) = DAG::Loader.from_yaml(yaml)
end
