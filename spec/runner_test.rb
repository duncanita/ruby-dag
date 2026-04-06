# frozen_string_literal: true

require_relative "test_helper"

class RunnerTest < Minitest::Test
  include TestHelpers

  # --- Basic execution ---

  def test_runs_single_node
    result = run_workflow({hello: {command: "echo hello"}})
    assert result.success?
    assert_equal "hello", result.value[:outputs][:hello].value
  end

  def test_zero_dep_step_receives_empty_hash
    defn = build_test_workflow(
      solo: {type: :ruby, callable: ->(input) { DAG::Success.new(value: input) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal({}, result.value[:outputs][:solo].value)
  end

  def test_single_dep_step_receives_hash_keyed_by_dep_name
    defn = build_test_workflow(
      produce: {},
      consume: {type: :ruby, depends_on: [:produce],
                callable: ->(input) { DAG::Success.new(value: "got: #{input}") }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal "got: {produce: \"produce\"}", result.value[:outputs][:consume].value
  end

  def test_merges_multiple_dependency_outputs
    defn = build_test_workflow(
      x: {command: "echo X"},
      y: {command: "echo Y"},
      merge: {type: :ruby, depends_on: [:x, :y],
              callable: ->(input) { DAG::Success.new(value: input.values.sort.join("+")) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal "X+Y", result.value[:outputs][:merge].value
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
    assert_equal :exec_failed, result.error[:error][:code]
    assert_equal 42, result.error[:error][:exit_status]
  end

  # --- Parallel execution ---

  def test_parallel_independent_nodes
    result = run_workflow(
      {a: {command: "echo a"}, b: {command: "echo b"}},
      parallel: true
    )

    assert result.success?
    assert_equal "a", result.value[:outputs][:a].value
    assert_equal "b", result.value[:outputs][:b].value
  end

  def test_sequential_independent_nodes
    result = run_workflow(
      {a: {command: "echo a"}, b: {command: "echo b"}},
      parallel: false
    )

    assert result.success?
    assert_equal "a", result.value[:outputs][:a].value
    assert_equal "b", result.value[:outputs][:b].value
  end

  # --- File pipeline ---

  def test_read_transform_write_pipeline
    input_path = "/tmp/dag_test_in_#{$$}.txt"
    output_path = "/tmp/dag_test_out_#{$$}.txt"
    File.write(input_path, "hello world")

    defn = build_test_workflow(
      read: {type: :file_read, path: input_path},
      transform: {type: :ruby, depends_on: [:read],
                  callable: ->(input) { DAG::Success.new(value: input[:read].upcase) }},
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
      on_step_start: ->(name, _step) { started << name },
      on_step_finish: ->(name, _result) { finished << name }).call

    assert_equal [:a, :b], started
    assert_equal [:a, :b], finished
  end

  def test_callbacks_fire_for_parallel_nodes
    finished = []

    defn = build_test_workflow(a: {}, b: {})

    DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true,
      on_step_finish: ->(name, _result) { finished << name }).call

    assert_includes finished, :a
    assert_includes finished, :b
  end

  # --- Definition convenience methods ---

  def test_definition_empty
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    defn = DAG::Workflow::Definition.new(graph: graph, registry: registry)
    assert defn.empty?
  end

  def test_definition_steps
    defn = build_test_workflow(a: {}, b: {depends_on: [:a]})
    steps = defn.steps
    assert_equal 2, steps.size
    assert steps.all? { |s| s.is_a?(DAG::Workflow::Step) }
  end

  # --- Execution trace ---

  def test_successful_result_has_trace
    result = run_workflow({hello: {command: "echo hello"}})
    assert result.success?
    assert_kind_of Array, result.value[:trace]
    assert_equal 1, result.value[:trace].size
  end

  def test_trace_entry_has_required_fields
    result = run_workflow({hello: {command: "echo hello"}})
    entry = result.value[:trace].first
    assert_equal :hello, entry.name
    assert_equal 0, entry.layer
    assert_kind_of Numeric, entry.duration_ms
    assert_equal :success, entry.status
    assert_equal [], entry.input_keys
  end

  def test_trace_includes_layer_info
    defn = build_test_workflow(
      a: {},
      b: {depends_on: [:a]}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    trace = result.value[:trace]
    assert_equal 0, trace.find { |e| e.name == :a }.layer
    assert_equal 1, trace.find { |e| e.name == :b }.layer
  end

  def test_failed_result_has_trace
    defn = build_test_workflow(
      good: {},
      bad: {command: "exit 1", depends_on: [:good]}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert result.failure?
    assert_kind_of Array, result.error[:trace]
    assert_equal 2, result.error[:trace].size
    assert_equal :failure, result.error[:trace].last.status
  end

  # --- Unknown callback keyword ---

  def test_rejects_unknown_callback_keyword
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    assert_raises(ArgumentError) do
      DAG::Workflow::Runner.new(graph, registry, on_typo_key: ->(*) {})
    end
  end

  # --- Edge cases ---

  def test_raises_when_graph_has_unregistered_steps
    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a"))

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Runner.new(graph, registry, parallel: false)
    end
    assert_match(/b/, error.message)
  end

  def test_runner_degrades_unsafe_layer_to_sequential
    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo safe"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby, callable: ->(input) { DAG::Success.new(value: "from ruby") }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: true).call
    assert result.success?
    assert_equal "safe", result.value[:outputs][:a].value
    assert_equal "from ruby", result.value[:outputs][:b].value
  end

  # --- Conditional execution ---

  def test_skipped_step_when_condition_false
    graph = DAG::Graph.new.add_node(:a).add_node(:b).add_edge(:a, :b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo hello"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby,
      callable: ->(input) { DAG::Success.new(value: "ran") },
      run_if: ->(input) { false }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_nil result.value[:outputs][:b].value
  end

  def test_step_runs_when_condition_true
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(input) { DAG::Success.new(value: "ran") },
      run_if: ->(input) { true }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_equal "ran", result.value[:outputs][:a].value
  end

  def test_skipped_step_trace_has_skipped_status
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(input) { DAG::Success.new(value: "ran") },
      run_if: ->(input) { false }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    trace = result.value[:trace]
    assert_equal :skipped, trace.first.status
  end

  def test_step_without_condition_always_runs
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo always"))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_equal "always", result.value[:outputs][:a].value
  end

  def test_empty_graph_succeeds
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_equal({}, result.value[:outputs])
    assert_equal([], result.value[:trace])
  end

  # --- Registry mutations ---

  def test_registry_replace_updates_step
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo old"))
    registry.replace(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo new"))

    assert_equal "echo new", registry[:a].config[:command]
  end

  def test_registry_replace_unknown_raises
    registry = DAG::Workflow::Registry.new
    assert_raises(ArgumentError) do
      registry.replace(DAG::Workflow::Step.new(name: :missing, type: :exec, command: "echo x"))
    end
  end

  def test_registry_remove_drops_step
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a"))
    registry.remove(:a)

    refute registry.key?(:a)
  end

  def test_registry_remove_unknown_raises
    registry = DAG::Workflow::Registry.new
    assert_raises(ArgumentError) { registry.remove(:missing) }
  end

  def test_registry_dup_is_independent
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo old"))
    duped = registry.dup
    duped.replace(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo new"))

    assert_equal "echo old", registry[:a].config[:command]
    assert_equal "echo new", duped[:a].config[:command]
  end

  # --- Definition#replace_step ---

  def test_definition_replace_step_same_name_keeps_graph
    defn = build_test_workflow(a: {}, b: {depends_on: [:a]})
    new_step = DAG::Workflow::Step.new(name: :b, type: :exec, command: "echo updated")
    new_defn = defn.replace_step(:b, new_step)

    assert_equal "echo updated", new_defn.step(:b).config[:command]
    assert_equal defn.graph, new_defn.graph
  end

  def test_definition_replace_step_different_name_renames_graph
    defn = build_test_workflow(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:b]})
    new_step = DAG::Workflow::Step.new(name: :x, type: :exec, command: "echo x")
    new_defn = defn.replace_step(:b, new_step)

    assert new_defn.graph.node?(:x)
    refute new_defn.graph.node?(:b)
    assert new_defn.graph.edge?(:a, :x)
    assert new_defn.graph.edge?(:x, :c)
    assert_equal :x, new_defn.step(:x).name
  end

  def test_definition_replace_step_preserves_edge_metadata
    graph = DAG::Graph.new.add_node(:a).add_node(:b).add_node(:c)
    graph.add_edge(:a, :b, weight: 4)
    graph.add_edge(:b, :c, weight: 6)
    registry = DAG::Workflow::Registry.new
    [:a, :b, :c].each { |n| registry.register(DAG::Workflow::Step.new(name: n, type: :exec, command: "echo #{n}")) }
    defn = DAG::Workflow::Definition.new(graph: graph, registry: registry)

    new_step = DAG::Workflow::Step.new(name: :x, type: :exec, command: "echo x")
    new_defn = defn.replace_step(:b, new_step)

    assert_equal({weight: 4}, new_defn.graph.edge_metadata(:a, :x))
    assert_equal({weight: 6}, new_defn.graph.edge_metadata(:x, :c))
  end

  def test_definition_replace_step_original_unchanged
    defn = build_test_workflow(a: {}, b: {depends_on: [:a]})
    new_step = DAG::Workflow::Step.new(name: :x, type: :exec, command: "echo x")
    defn.replace_step(:b, new_step)

    assert defn.graph.node?(:b)
    refute defn.graph.node?(:x)
    assert_equal :b, defn.step(:b).name
  end

  def test_definition_replace_step_unknown_raises
    defn = build_test_workflow(a: {})
    new_step = DAG::Workflow::Step.new(name: :x, type: :exec, command: "echo x")
    assert_raises(DAG::UnknownNodeError) { defn.replace_step(:missing, new_step) }
  end

  def test_definition_replace_step_runs_correctly
    defn = build_test_workflow(a: {}, b: {depends_on: [:a]})
    new_step = DAG::Workflow::Step.new(name: :b, type: :exec, command: "echo replaced")
    new_defn = defn.replace_step(:b, new_step)

    result = DAG::Workflow::Runner.new(new_defn.graph, new_defn.registry, parallel: false).call
    assert result.success?
    assert_equal "replaced", result.value[:outputs][:b].value
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
