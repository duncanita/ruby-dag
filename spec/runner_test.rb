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
                callable: ->(input) { DAG::Success.new(value: input) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal({produce: "produce"}, result.value[:outputs][:consume].value)
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
    assert_equal :fail_node, result.error[:error][:failed_node]
    refute result.error[:outputs].key?(:never_runs)
  end

  def test_failure_includes_error_detail
    result = run_workflow({bad: {command: "echo fail >&2; exit 42"}})
    assert result.failure?
    assert_equal :exec_failed, result.error[:error][:step_error][:code]
    assert_equal 42, result.error[:error][:step_error][:exit_status]
  end

  def test_success_and_failure_share_payload_keys
    success = run_workflow({good: {command: "echo good"}})
    failure = run_workflow({bad: {command: "exit 1"}})

    assert success.success?
    assert failure.failure?
    assert_equal [:outputs, :trace, :error].sort, success.value.keys.sort
    assert_equal [:outputs, :trace, :error].sort, failure.error.keys.sort
    assert_nil success.value[:error]
    refute_nil failure.error[:error]
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

  def test_start_callback_does_not_fire_for_skipped_steps
    started = []
    finished = []

    graph = DAG::Graph.new.add_node(:a).add_node(:b).add_node(:c)
      .add_edge(:a, :c).add_edge(:b, :c)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(_input) { DAG::Success.new(value: "ran") }))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby,
      callable: ->(_input) { DAG::Success.new(value: "never") },
      run_if: ->(_input) { false }))
    registry.register(DAG::Workflow::Step.new(name: :c, type: :ruby,
      callable: ->(_input) { DAG::Success.new(value: "also ran") }))

    DAG::Workflow::Runner.new(graph, registry, parallel: false,
      on_step_start: ->(name, _step) { started << name },
      on_step_finish: ->(name, _result) { finished << name }).call

    # Skipped step :b never triggers :start, but its :finish still fires
    # (this matches the existing Runner contract — skipped steps write a
    # trace entry and call on_step_finish with a nil Success).
    assert_equal [:a, :c], started
    assert_includes finished, :a
    assert_includes finished, :b
    assert_includes finished, :c
  end

  # --- Runner accepts a Definition directly ---

  def test_runner_accepts_definition
    defn = build_test_workflow(a: {command: "echo a"})
    result = DAG::Workflow::Runner.new(defn, parallel: false).call
    assert result.success?
    assert_equal "a", result.value[:outputs][:a].value
  end

  def test_runner_definition_form_rejects_extra_registry
    defn = build_test_workflow(a: {command: "echo a"})
    assert_raises(ArgumentError) do
      DAG::Workflow::Runner.new(defn, defn.registry, parallel: false)
    end
  end

  def test_runner_pair_form_requires_registry
    graph = DAG::Graph.new.add_node(:a)
    assert_raises(ArgumentError) do
      DAG::Workflow::Runner.new(graph, parallel: false)
    end
  end

  # --- Callback ordering with mixed skipped/runnable in one layer ---

  def test_start_callbacks_fire_before_any_finish_in_mixed_layer
    events = []

    graph = DAG::Graph.new.add_node(:run).add_node(:skip)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :run, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "ran") }))
    registry.register(DAG::Workflow::Step.new(name: :skip, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: ->(_) { false }))

    DAG::Workflow::Runner.new(graph, registry, parallel: false,
      on_step_start: ->(name, _step) { events << [:start, name] },
      on_step_finish: ->(name, _result) { events << [:finish, name] }).call

    # All :start events for the layer must come before the first :finish.
    first_finish = events.index { |kind, _| kind == :finish }
    before = events[0...first_finish]
    assert before.all? { |kind, _| kind == :start },
      "expected all :start before first :finish, got #{events.inspect}"
    # And :start fires only for the runnable step.
    assert_includes events, [:start, :run]
    refute_includes events, [:start, :skip]
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

  def test_threads_strategy_handles_mixed_step_types
    # Threads (the default for parallel: true) shares memory, so a layer
    # mixing :exec and :ruby steps just runs in the pool directly.
    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo safe"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby, callable: ->(_input) { DAG::Success.new(value: "from ruby") }))

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

  # --- run_if exception containment ---

  def test_run_if_exception_produces_failure_not_crash
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: ->(_) { raise "predicate boom" }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call

    assert result.failure?
    assert_equal :a, result.error[:error][:failed_node]
    step_error = result.error[:error][:step_error]
    assert_equal :run_if_error, step_error[:code]
    assert_match(/predicate boom/, step_error[:message])
    assert_equal "RuntimeError", step_error[:error_class]
  end

  def test_run_if_exception_records_trace_entry
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: ->(_) { raise "boom" }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call

    trace = result.error[:trace]
    assert_equal 1, trace.size
    entry = trace.first
    assert_equal :a, entry.name
    assert_equal :failure, entry.status
    assert_nil entry.started_at
    assert_nil entry.finished_at
  end

  def test_run_if_exception_does_not_fire_start_callback
    started = []
    finished = []

    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: ->(_) { raise "boom" }))

    DAG::Workflow::Runner.new(graph, registry, parallel: false,
      on_step_start: ->(name, _) { started << name },
      on_step_finish: ->(name, _) { finished << name }).call

    assert_empty started
    assert_equal [:a], finished
  end

  def test_run_if_failure_still_preserves_start_before_finish_order_in_mixed_layer
    events = []

    graph = DAG::Graph.new.add_node(:run).add_node(:bad)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :run, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "ok") }))
    registry.register(DAG::Workflow::Step.new(name: :bad, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: ->(_) { raise "boom" }))

    DAG::Workflow::Runner.new(graph, registry, parallel: false,
      on_step_start: ->(name, _) { events << [:start, name] },
      on_step_finish: ->(name, _) { events << [:finish, name] }).call

    first_finish = events.index { |kind, _| kind == :finish }
    before = events[0...first_finish]
    assert before.all? { |kind, _| kind == :start },
      "expected all :start before first :finish, got #{events.inspect}"
  end

  def test_run_if_exception_preserves_prior_outputs
    graph = DAG::Graph.new.add_node(:ok).add_node(:bad).add_edge(:ok, :bad)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :ok, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "fine") }))
    registry.register(DAG::Workflow::Step.new(name: :bad, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: ->(_) { raise "conditional exploded" }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call

    assert result.failure?
    assert_equal [:error, :outputs, :trace], result.error.keys.sort
    assert result.error[:outputs][:ok].success?
  end

  def test_empty_graph_succeeds
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_equal({}, result.value[:outputs])
    assert_equal([], result.value[:trace])
  end

  # --- Workflow-level timeout ---

  def test_workflow_timeout_halts_between_layers
    defn = build_test_workflow(
      slow: {command: "sleep 0.5; echo done"},
      after: {depends_on: [:slow]}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false, timeout: 0.1).call

    assert result.failure?
    assert_equal :workflow_timeout, result.error[:error][:failed_node]
    assert_equal :workflow_timeout, result.error[:error][:step_error][:code]
    assert_equal 0.1, result.error[:error][:step_error][:timeout_seconds]
  end

  def test_workflow_timeout_does_not_fire_when_under_budget
    defn = build_test_workflow(quick: {command: "echo fast"})
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false, timeout: 5).call
    assert result.success?
    assert_equal "fast", result.value[:outputs][:quick].value
  end

  def test_workflow_timeout_nil_means_no_timeout
    defn = build_test_workflow(a: {command: "echo a"})
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false, timeout: nil).call
    assert result.success?
  end

  # --- Registry mutations ---

  def test_registry_register_rejects_duplicate
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a"))
    error = assert_raises(ArgumentError) do
      registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo b"))
    end
    assert_match(/Duplicate step: a/, error.message)
  end

  def test_registry_inspect_lists_step_names
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :alpha, type: :exec, command: "echo a"))
    registry.register(DAG::Workflow::Step.new(name: :beta, type: :exec, command: "echo b"))
    assert_match(/Registry steps=\[:alpha, :beta\]/, registry.inspect)
  end

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
    # Same-name replace returns the same Graph reference (no rebuild needed),
    # so identity is the right check here.
    assert_same defn.graph, new_defn.graph
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
