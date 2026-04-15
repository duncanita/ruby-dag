# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

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

  # depends_on is reachable via Step.new — the custom initializer splats
  # extra kwargs into config, so `depends_on: [...]` lands in the config
  # hash and would silently overwrite the structural depends_on field.
  def test_raises_on_config_key_collision_with_depends_on
    graph = DAG::Graph.new.add_node(:oops)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :oops, type: :exec, command: "true", depends_on: ["sneaky"]))
    defn = DAG::Workflow::Definition.new(graph: graph, registry: registry)

    error = assert_raises(DAG::SerializationError) { DAG::Workflow::Dumper.to_yaml(defn) }
    assert_match(/reserved YAML key/, error.message)
    assert_match(/depends_on/, error.message)
  end

  # :type is NOT reachable via Step.new (the custom initializer extracts
  # it as a kwarg before it can hit the config splat) but the Dumper's
  # collision guard is defense-in-depth for any future Step subclass or
  # Registry that might carry a differently-shaped step. Use a duck-typed
  # Struct stand-in to exercise the :type branch of the guard directly.
  def test_raises_on_config_key_collision_with_type
    fake_step_class = Struct.new(:name, :type, :config)
    fake = fake_step_class.new(:oops, :exec, {type: "sneaky", command: "true"})
    graph = DAG::Graph.new.add_node(:oops)
    registry = DAG::Workflow::Registry.new
    registry.register(fake)
    defn = DAG::Workflow::Definition.new(graph: graph, registry: registry)

    error = assert_raises(DAG::SerializationError) { DAG::Workflow::Dumper.to_yaml(defn) }
    assert_match(/reserved YAML key/, error.message)
    assert_match(/'type'/, error.message)
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

    assert_equal defn1.graph.freeze, defn2.graph.freeze
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

      assert_equal defn1.graph.freeze, defn2.graph.freeze, "Round-trip failed for #{File.basename(path)}"
    end
  end

  def test_to_file
    defn = build_test_workflow(greet: {type: :exec, command: "echo hello"})

    Tempfile.create(["dumper_test", ".yml"]) do |f|
      DAG::Workflow::Dumper.to_file(defn, f.path)
      loaded = DAG::Workflow::Loader.from_file(f.path)
      assert_equal defn.graph.freeze, loaded.graph.freeze
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

  def test_round_trip_with_versioned_dependency_metadata
    defn1 = build_test_workflow(
      source: {type: :exec, command: "echo data"},
      consume_history: {
        type: :exec,
        command: "echo use-history",
        depends_on: [{from: :source, version: :all, as: :history}]
      }
    )

    dumped = DAG::Workflow::Dumper.to_yaml(defn1)
    defn2 = DAG::Workflow::Loader.from_yaml(dumped)

    assert_equal({version: :all, as: :history}, defn2.graph.edge_metadata(:source, :consume_history))
  end

  def test_round_trip_with_declarative_run_if
    yaml = <<~YAML
      nodes:
        decide:
          type: exec
          command: "echo prod"
        deploy:
          type: exec
          command: "echo deploy"
          depends_on:
            - decide
          run_if:
            any:
              - from: decide
                status: success
              - from: decide
                value:
                  equals: "prod"
    YAML

    defn1 = DAG::Workflow::Loader.from_yaml(yaml)
    dumped = DAG::Workflow::Dumper.to_yaml(defn1)
    defn2 = DAG::Workflow::Loader.from_yaml(dumped)

    assert_equal defn1.step(:deploy).config[:run_if], defn2.step(:deploy).config[:run_if]
  end

  def test_raises_on_callable_run_if
    graph = DAG::Graph.new.add_node(:deploy)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :deploy, type: :exec,
      command: "echo deploy", run_if: ->(_) { true }))
    defn = DAG::Workflow::Definition.new(graph: graph, registry: registry)

    error = assert_raises(DAG::SerializationError) { DAG::Workflow::Dumper.to_yaml(defn) }
    assert_match(/run_if/, error.message)
    assert_match(/YAML-serializable/, error.message)
  end

  # Symbol values in step config used to break round-trip: Dumper happily
  # emitted `mode: :strict` but Loader's safe_load did not permit Symbol
  # and crashed with Psych::DisallowedClass. Both sides should now agree.
  def test_round_trip_with_symbol_config_values
    defn1 = build_test_workflow(task: {type: :exec, command: "echo x", mode: :strict})
    dumped = DAG::Workflow::Dumper.to_yaml(defn1)
    defn2 = DAG::Workflow::Loader.from_yaml(dumped)

    assert_equal :strict, defn2.step(:task).config[:mode]
  end

  def test_round_trip_schedule_metadata_with_yaml_safe_values
    defn1 = build_test_workflow(task: {
      type: :exec,
      command: "echo x",
      schedule: {
        not_before: Time.utc(2026, 4, 15, 9, 0, 0),
        not_after: Time.utc(2026, 4, 15, 10, 0, 0),
        ttl: 3600,
        cron: "0 * * * *"
      }
    })

    dumped = DAG::Workflow::Dumper.to_yaml(defn1)
    parsed = YAML.safe_load(dumped)
    schedule = parsed.fetch("nodes").fetch("task").fetch("schedule")
    defn2 = DAG::Workflow::Loader.from_yaml(dumped)

    assert_equal "2026-04-15T09:00:00Z", schedule["not_before"]
    assert_equal "2026-04-15T10:00:00Z", schedule["not_after"]
    assert_equal 3600, schedule["ttl"]
    assert_equal "0 * * * *", schedule["cron"]
    assert_equal({
      not_before: "2026-04-15T09:00:00Z",
      not_after: "2026-04-15T10:00:00Z",
      ttl: 3600,
      cron: "0 * * * *"
    }, defn2.step(:task).config[:schedule])
  end

  def test_round_trip_sub_workflow_with_definition_path_via_file
    Dir.mktmpdir("dag-dumper-subworkflow") do |dir|
      child_path = File.join(dir, "child.yml")
      parent_path = File.join(dir, "parent.yml")

      File.write(child_path, <<~YAML)
        nodes:
          summarize:
            type: exec
            command: "printf dumped-child"
      YAML

      graph = DAG::Graph.new.add_node(:process)
      registry = DAG::Workflow::Registry.new
      registry.register(DAG::Workflow::Step.new(name: :process, type: :sub_workflow,
        definition_path: "child.yml", output_key: :summarize))
      defn = DAG::Workflow::Definition.new(graph: graph, registry: registry, source_path: parent_path)

      DAG::Workflow::Dumper.to_file(defn, parent_path)
      loaded = DAG::Workflow::Loader.from_file(parent_path)
      result = DAG::Workflow::Runner.new(loaded, parallel: false).call

      assert result.success?
      assert_equal "child.yml", loaded.step(:process).config[:definition_path]
      assert_equal "dumped-child", result.outputs[:process].value
    end
  end

  def test_raises_on_programmatic_sub_workflow_definition
    child = build_test_workflow(done: {type: :exec, command: "printf ok"})
    defn = build_test_workflow(process: {type: :sub_workflow, definition: child, output_key: :done})

    error = assert_raises(DAG::SerializationError) { DAG::Workflow::Dumper.to_yaml(defn) }
    assert_match(/definition_path/, error.message)
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
