# frozen_string_literal: true

require_relative "test_helper"

class DumperTest < Minitest::Test
  include TestHelpers

  def test_dumps_single_step
    defn = build_test_workflow(greet: {type: :exec, command: "echo hello"})
    yaml = DAG::Workflow::Dumper.to_yaml(defn)
    parsed = YAML.safe_load(yaml)

    assert_equal({"type" => "exec", "command" => "echo hello"}, parsed["nodes"]["greet"])
  end

  def test_dumps_dependencies
    defn = build_test_workflow(
      first: {type: :exec, command: "echo 1"},
      second: {type: :exec, command: "echo 2", depends_on: [:first]}
    )
    yaml = DAG::Workflow::Dumper.to_yaml(defn)
    parsed = YAML.safe_load(yaml)

    assert_equal ["first"], parsed["nodes"]["second"]["depends_on"]
    assert_nil parsed["nodes"]["first"]["depends_on"]
  end

  def test_topological_order_in_output
    defn = build_test_workflow(
      c: {type: :exec, command: "echo c", depends_on: [:b]},
      a: {type: :exec, command: "echo a"},
      b: {type: :exec, command: "echo b", depends_on: [:a]}
    )
    yaml = DAG::Workflow::Dumper.to_yaml(defn)
    keys = YAML.safe_load(yaml)["nodes"].keys

    assert_equal %w[a b c], keys
  end

  def test_preserves_extra_config
    defn = build_test_workflow(task: {type: :exec, command: "echo x", timeout: 60})
    yaml = DAG::Workflow::Dumper.to_yaml(defn)
    parsed = YAML.safe_load(yaml)

    assert_equal 60, parsed["nodes"]["task"]["timeout"]
  end

  def test_raises_on_ruby_type
    defn = build_test_workflow(bad: {type: :ruby, callable: -> { "nope" }})

    assert_raises(DAG::SerializationError) { DAG::Workflow::Dumper.to_yaml(defn) }
  end

  def test_round_trip
    original_yaml = <<~YAML
      nodes:
        fetch:
          type: exec
          command: "echo data"
          timeout: 10
        transform:
          type: exec
          command: "echo transformed"
          depends_on:
            - fetch
        save:
          type: file_write
          path: "/tmp/out.txt"
          depends_on:
            - transform
    YAML

    defn1 = DAG::Workflow::Loader.from_yaml(original_yaml)
    dumped = DAG::Workflow::Dumper.to_yaml(defn1)
    defn2 = DAG::Workflow::Loader.from_yaml(dumped)

    assert_equal defn1.graph, defn2.graph
    defn1.graph.topological_sort.each do |name|
      assert_equal defn1.step(name).type, defn2.step(name).type
      assert_equal defn1.step(name).config, defn2.step(name).config
    end
  end

  def test_round_trip_example_files
    Dir[File.expand_path("../../examples/*.yml", __FILE__)].each do |path|
      defn1 = DAG::Workflow::Loader.from_file(path)
      dumped = DAG::Workflow::Dumper.to_yaml(defn1)
      defn2 = DAG::Workflow::Loader.from_yaml(dumped)

      assert_equal defn1.graph, defn2.graph, "Round-trip failed for #{File.basename(path)}"
    end
  end

  def test_to_file
    defn = build_test_workflow(greet: {type: :exec, command: "echo hello"})

    Tempfile.create(["dumper_test", ".yml"]) do |f|
      DAG::Workflow::Dumper.to_file(defn, f.path)
      loaded = DAG::Workflow::Loader.from_file(f.path)
      assert_equal defn.graph, loaded.graph
    end
  end

  def test_round_trip_with_edge_metadata
    yaml = <<~YAML
      nodes:
        fetch:
          type: exec
          command: "echo data"
        parse:
          type: exec
          command: "echo parsed"
          depends_on:
            - from: fetch
              weight: 3
    YAML

    defn1 = DAG::Workflow::Loader.from_yaml(yaml)
    assert_equal({weight: 3}, defn1.graph.edge_metadata(:fetch, :parse))

    dumped = DAG::Workflow::Dumper.to_yaml(defn1)
    defn2 = DAG::Workflow::Loader.from_yaml(dumped)
    assert_equal({weight: 3}, defn2.graph.edge_metadata(:fetch, :parse))
  end

  def test_empty_workflow
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    defn = DAG::Workflow::Definition.new(graph: graph, registry: registry)
    yaml = DAG::Workflow::Dumper.to_yaml(defn)
    parsed = YAML.safe_load(yaml)

    assert_equal({}, parsed["nodes"])
  end
end
