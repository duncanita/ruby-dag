# frozen_string_literal: true

require_relative "test_helper"

class RunnerTest < Minitest::Test
  include TestHelpers

  # --- Basic execution ---

  def test_runs_single_node
    result = run_workflow({hello: {command: "echo hello"}})
    assert result.success?
    assert_equal "hello", result.outputs[:hello].value
  end

  def test_zero_dep_step_receives_empty_hash
    defn = build_test_workflow(
      solo: {type: :ruby, callable: ->(input) { DAG::Success.new(value: input) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal({}, result.outputs[:solo].value)
  end

  def test_single_dep_step_receives_hash_keyed_by_dep_name
    defn = build_test_workflow(
      produce: {},
      consume: {type: :ruby, depends_on: [:produce],
                callable: ->(input) { DAG::Success.new(value: input) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal({produce: "produce"}, result.outputs[:consume].value)
  end

  def test_merges_multiple_dependency_outputs
    defn = build_test_workflow(
      x: {command: "echo X"},
      y: {command: "echo Y"},
      merge: {type: :ruby, depends_on: [:x, :y],
              callable: ->(input) { DAG::Success.new(value: input.values.sort.join("+")) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    assert_equal "X+Y", result.outputs[:merge].value
  end

  def test_runner_resolves_versioned_dependency_inputs_from_execution_store
    store = build_memory_store
    clock = build_clock
    source_calls = 0

    definition = build_test_workflow(
      source: {
        type: :ruby,
        resume_key: "source-v1",
        schedule: {ttl: 1},
        callable: ->(_input) do
          source_calls += 1
          DAG::Success.new(value: "scan-#{source_calls}")
        end
      },
      latest_value: {
        type: :ruby,
        depends_on: [{from: :source, as: :latest_value}],
        schedule: {ttl: 1},
        resume_key: "latest-value-v1",
        callable: ->(input) { DAG::Success.new(value: input[:latest_value]) }
      },
      first_value: {
        type: :ruby,
        depends_on: [{from: :source, version: 1, as: :first_value}],
        schedule: {ttl: 1},
        resume_key: "first-value-v1",
        callable: ->(input) { DAG::Success.new(value: input[:first_value]) }
      },
      history: {
        type: :ruby,
        depends_on: [{from: :source, version: :all, as: :history}],
        schedule: {ttl: 1},
        resume_key: "history-v1",
        callable: ->(input) { DAG::Success.new(value: input[:history]) }
      }
    )

    first_run = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      execution_store: store,
      workflow_id: "wf-versioned-inputs").call
    assert_equal "scan-1", first_run.outputs[:source].value

    clock.advance(2)

    second_run = DAG::Workflow::Runner.new(definition,
      parallel: false,
      clock: clock,
      execution_store: store,
      workflow_id: "wf-versioned-inputs").call

    assert_equal 2, source_calls
    assert_equal "scan-2", second_run.outputs[:latest_value].value
    assert_equal "scan-1", second_run.outputs[:first_value].value
    assert_equal ["scan-1", "scan-2"], second_run.outputs[:history].value
  end

  def test_runner_fails_when_requested_local_dependency_version_is_missing
    store = build_memory_store

    definition = build_test_workflow(
      source: {
        type: :ruby,
        resume_key: "source-v1",
        callable: ->(_input) { DAG::Success.new(value: "scan-1") }
      },
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, version: 2, as: :missing_version}],
        resume_key: "consumer-v1",
        callable: ->(input) { DAG::Success.new(value: input[:missing_version]) }
      }
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      execution_store: store,
      workflow_id: "wf-missing-version").call

    assert_equal :failed, result.status
    assert_equal :consumer, result.error[:failed_node]
    assert_equal :missing_dependency_version, result.error[:step_error][:code]
    assert_match(/version 2/, result.error[:step_error][:message])
  end

  def test_runner_waits_when_cross_workflow_version_is_unavailable
    store = build_memory_store
    resolver_calls = 0
    resolver = lambda do |workflow_id, node_name, version|
      resolver_calls += 1
      next nil if resolver_calls == 1

      store.load_output(workflow_id: workflow_id, node_path: [node_name], version: version)
    end

    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "pipeline-a", node: :validated_output, version: 2, as: :validated}],
        resume_key: "consumer-v1",
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )

    first = DAG::Workflow::Runner.new(definition,
      parallel: false,
      cross_workflow_resolver: resolver,
      execution_store: store,
      workflow_id: "wf-cross-version").call

    assert_equal :waiting, first.status
    assert_equal [[:consumer]], first.waiting_nodes
    assert_equal :waiting, store.load_run("wf-cross-version")[:workflow_status]

    store.begin_run(workflow_id: "pipeline-a", definition_fingerprint: "fp-external", node_paths: [[:validated_output]])
    store.save_output(
      workflow_id: "pipeline-a",
      node_path: [:validated_output],
      version: 2,
      result: DAG::Success.new(value: "external-v2"),
      reusable: true,
      superseded: false
    )

    second = DAG::Workflow::Runner.new(definition,
      parallel: false,
      cross_workflow_resolver: resolver,
      execution_store: store,
      workflow_id: "wf-cross-version").call

    assert_equal :completed, second.status
    assert_equal "external-v2", second.outputs[:consumer].value
  end

  def test_runner_fails_when_cross_workflow_resolver_raises
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "pipeline-a", node: :validated_output, version: 2, as: :validated}],
        resume_key: "consumer-v1",
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      cross_workflow_resolver: ->(*) { raise "resolver exploded" },
      execution_store: build_memory_store,
      workflow_id: "wf-cross-version-error").call

    assert_equal :failed, result.status
    assert_equal :consumer, result.error[:failed_node]
    assert_equal :cross_workflow_resolution_failed, result.error[:step_error][:code]
    assert_match(/resolver exploded/, result.error[:step_error][:message])
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
    refute result.outputs.key?(:never_runs)
  end

  def test_failure_includes_error_detail
    result = run_workflow({bad: {command: "echo fail >&2; exit 42"}})
    assert result.failure?
    assert_equal :exec_failed, result.error[:step_error][:code]
    assert_equal 42, result.error[:step_error][:exit_status]
  end

  def test_failed_nodes_are_not_exposed_in_outputs
    definition = build_test_workflow(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "ready") }
      },
      explode: {
        type: :ruby,
        depends_on: [:fetch],
        callable: ->(_input) { DAG::Failure.new(error: {code: :boom, message: "explode"}) }
      }
    )

    result = DAG::Workflow::Runner.new(definition, parallel: false).call

    assert_equal :failed, result.status
    assert_equal "ready", result.outputs[:fetch].value
    refute result.outputs.key?(:explode)
  end

  def test_runner_returns_workflow_run_result
    success = run_workflow({good: {command: "echo good"}})
    failure = run_workflow({bad: {command: "exit 1"}})

    assert_kind_of DAG::Workflow::RunResult, success
    assert_kind_of DAG::Workflow::RunResult, failure
    assert_equal :completed, success.status
    assert_equal :failed, failure.status
    assert_nil success.error
    assert_equal [], success.waiting_nodes
  end

  # --- Parallel execution ---

  def test_parallel_independent_nodes
    result = run_workflow(
      {a: {command: "echo a"}, b: {command: "echo b"}},
      parallel: true
    )

    assert result.success?
    assert_equal "a", result.outputs[:a].value
    assert_equal "b", result.outputs[:b].value
  end

  def test_sequential_independent_nodes
    result = run_workflow(
      {a: {command: "echo a"}, b: {command: "echo b"}},
      parallel: false
    )

    assert result.success?
    assert_equal "a", result.outputs[:a].value
    assert_equal "b", result.outputs[:b].value
  end

  # --- File pipeline ---

  def test_read_transform_write_pipeline
    input_path = temp_path(prefix: "dag_test_in")
    output_path = temp_path(prefix: "dag_test_out")
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
    assert_equal "a", result.outputs[:a].value
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

  # --- Step middleware ---

  def test_middleware_wraps_step_attempt_in_declaration_order
    events = []

    middleware_one = Class.new(DAG::Workflow::StepMiddleware) do
      def initialize(events)
        @events = events
      end

      def call(step, input, context:, execution:, next_step:)
        @events << [:before, :one, step.name, execution.node_path, execution.attempt, execution.parallel]
        result = next_step.call(step, input, context: context, execution: execution)
        @events << [:after, :one]
        DAG::Success.new(value: "#{result.value}|one")
      end
    end

    middleware_two = Class.new(DAG::Workflow::StepMiddleware) do
      def initialize(events)
        @events = events
      end

      def call(step, input, context:, execution:, next_step:)
        @events << [:before, :two, step.name, execution.node_path, execution.attempt, execution.parallel]
        result = next_step.call(step, input, context: context, execution: execution)
        @events << [:after, :two]
        DAG::Success.new(value: "#{result.value}|two")
      end
    end

    defn = build_test_workflow(
      wrapped: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "core") }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      middleware: [middleware_one.new(events), middleware_two.new(events)]).call

    assert result.success?
    assert_equal "core|two|one", result.outputs[:wrapped].value
    assert_equal [
      [:before, :one, :wrapped, [:wrapped], 1, :sequential],
      [:before, :two, :wrapped, [:wrapped], 1, :sequential],
      [:after, :two],
      [:after, :one]
    ], events
  end

  def test_middleware_can_short_circuit_step_attempt
    middleware = Class.new(DAG::Workflow::StepMiddleware) do
      def call(step, input, context:, execution:, next_step:)
        DAG::Success.new(value: "short-circuited #{step.name} with #{input.inspect}")
      end
    end

    defn = build_test_workflow(
      wrapped: {type: :ruby, callable: ->(_input) { raise "should not run" }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      middleware: [middleware.new]).call

    assert result.success?
    assert_equal "short-circuited wrapped with {}", result.outputs[:wrapped].value
  end

  def test_bad_middleware_return_fails_clearly
    middleware = Class.new(DAG::Workflow::StepMiddleware) do
      def call(step, input, context:, execution:, next_step:)
        "not a result"
      end
    end

    defn = build_test_workflow(
      wrapped: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "never") }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      middleware: [middleware.new]).call

    assert result.failure?
    assert_equal :wrapped, result.error[:failed_node]
    assert_equal :middleware_bad_return, result.error[:step_error][:code]
    assert_equal "String", result.error[:step_error][:returned_class]
    assert_match(/middleware .* returned String/, result.error[:step_error][:message])
  end

  # --- Context injection ---

  def test_runner_passes_context_to_compatible_step_handlers
    klass = Class.new do
      def call(step, input, context: nil)
        DAG::Success.new(value: [step.name, input, context])
      end
    end
    type = :"_test_context_handler_#{object_id}"
    DAG::Workflow::Steps.register(type, klass, yaml_safe: false)

    graph = DAG::Graph.new.add_node(:ctx)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :ctx, type: type))

    context = {request_id: "abc-123"}
    result = DAG::Workflow::Runner.new(graph, registry, parallel: false, context: context).call

    assert result.success?
    assert_equal [:ctx, {}, context], result.outputs[:ctx].value
  end

  def test_runner_keeps_old_step_handlers_working_without_context_keyword
    klass = Class.new do
      def call(step, input)
        DAG::Success.new(value: [step.name, input])
      end
    end
    type = :"_test_legacy_handler_#{object_id}"
    DAG::Workflow::Steps.register(type, klass, yaml_safe: false)

    graph = DAG::Graph.new.add_node(:legacy)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :legacy, type: type))

    result = DAG::Workflow::Runner.new(graph, registry,
      parallel: false,
      context: {ignored: true}).call

    assert result.success?
    assert_equal [:legacy, {}], result.outputs[:legacy].value
  end

  def test_ruby_step_passes_context_when_callable_accepts_second_positional_argument
    defn = build_test_workflow(
      ruby_ctx: {type: :ruby, callable: ->(input, context) { DAG::Success.new(value: [input, context]) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      context: {tenant: "acme"}).call

    assert result.success?
    assert_equal [{}, {tenant: "acme"}], result.outputs[:ruby_ctx].value
  end

  def test_ruby_step_ignores_context_when_callable_only_accepts_input
    defn = build_test_workflow(
      ruby_ctx: {type: :ruby, callable: ->(input) { DAG::Success.new(value: input) }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      context: {tenant: "acme"}).call

    assert result.success?
    assert_equal({}, result.outputs[:ruby_ctx].value)
  end

  def test_threads_mode_passes_context_to_compatible_handlers
    klass = Class.new do
      def call(step, input, context: nil)
        DAG::Success.new(value: context.fetch(:tenant))
      end
    end
    type = :"_test_thread_context_handler_#{object_id}"
    DAG::Workflow::Steps.register(type, klass, yaml_safe: false)

    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: type))
    registry.register(DAG::Workflow::Step.new(name: :b, type: type))

    result = DAG::Workflow::Runner.new(graph, registry,
      parallel: :threads,
      context: {tenant: "acme"}).call

    assert result.success?
    assert_equal "acme", result.outputs[:a].value
    assert_equal "acme", result.outputs[:b].value
  end

  def test_processes_mode_rejects_context_at_initialization
    defn = build_test_workflow(a: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "ok") }})

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Runner.new(defn.graph, defn.registry,
        parallel: :processes,
        context: {tenant: "acme"})
    end

    assert_match(/parallel: :processes/, error.message)
    assert_match(/context serialization hooks/, error.message)
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
    assert_kind_of Array, result.trace
    assert_equal 1, result.trace.size
  end

  def test_trace_entry_has_required_fields
    result = run_workflow({hello: {command: "echo hello"}})
    entry = result.trace.first
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
    trace = result.trace
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
    assert_kind_of Array, result.trace
    assert_equal 2, result.trace.size
    assert_equal :failure, result.trace.last.status
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
    assert_equal "safe", result.outputs[:a].value
    assert_equal "from ruby", result.outputs[:b].value
  end

  # --- Conditional execution ---

  def test_skipped_step_when_condition_false
    graph = DAG::Graph.new.add_node(:a).add_node(:b).add_node(:c)
      .add_edge(:a, :b).add_edge(:a, :c)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo hello"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby,
      callable: ->(input) { DAG::Success.new(value: "ran") },
      run_if: ->(input) { false }))
    registry.register(DAG::Workflow::Step.new(name: :c, type: :ruby,
      callable: ->(input) { DAG::Success.new(value: "fallback") }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_nil result.outputs[:b].value
    assert_equal "fallback", result.outputs[:c].value
  end

  def test_step_runs_when_condition_true
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(input) { DAG::Success.new(value: "ran") },
      run_if: ->(input) { true }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_equal "ran", result.outputs[:a].value
  end

  def test_skipped_step_trace_has_skipped_status
    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    graph.add_edge(:a, :b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(input) { DAG::Success.new(value: "ran") },
      run_if: ->(input) { false }))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "fallback") },
      run_if: ->(input) { input[:a].nil? }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    trace = result.trace
    assert_equal :skipped, trace.find { |entry| entry.name == :a }.status
  end

  def test_skipped_leaf_succeeds
    graph = DAG::Graph.new.add_node(:a).add_node(:b).add_edge(:a, :b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo hello"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: ->(_) { false }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call

    # Runner success means "no step failed." Skipped steps are not
    # failures — run_if intentionally filtered them.
    assert result.success?
    assert_nil result.error
    assert result.trace.any? { |e| e.status == :skipped }
  end

  def test_declarative_run_if_selects_branch_by_value
    graph = DAG::Graph.new.add_node(:decide).add_node(:prod).add_node(:noop)
    graph.add_edge(:decide, :prod)
    graph.add_edge(:decide, :noop)

    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :decide, type: :exec, command: "echo prod"))
    registry.register(DAG::Workflow::Step.new(name: :prod, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "deploy prod") },
      run_if: {from: :decide, value: {equals: "prod"}}))
    registry.register(DAG::Workflow::Step.new(name: :noop, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "no-op") },
      run_if: {from: :decide, value: {equals: "staging"}}))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call

    assert result.success?
    assert_equal "deploy prod", result.outputs[:prod].value
    assert_nil result.outputs[:noop].value
  end

  def test_declarative_run_if_can_follow_skipped_dependency_status
    graph = DAG::Graph.new.add_node(:root).add_node(:conditional).add_node(:fallback)
    graph.add_edge(:root, :conditional)
    graph.add_edge(:conditional, :fallback)

    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :root, type: :exec, command: "echo root"))
    registry.register(DAG::Workflow::Step.new(name: :conditional, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: {from: :root, value: {equals: "skip-me"}}))
    registry.register(DAG::Workflow::Step.new(name: :fallback, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "fallback path") },
      run_if: {from: :conditional, status: :skipped}))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call

    assert result.success?
    assert_equal "fallback path", result.outputs[:fallback].value
  end

  def test_runner_rejects_invalid_declarative_run_if_on_manual_definition
    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    graph.add_edge(:a, :b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "bad") },
      run_if: {from: :missing, status: :success}))

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Runner.new(graph, registry, parallel: false)
    end

    assert_match(/direct dependencies/, error.message)
    assert_match(/missing/, error.message)
  end

  def test_step_without_condition_always_runs
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo always"))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_equal "always", result.outputs[:a].value
  end

  # --- layer admission error contract ---

  def test_run_if_exception_produces_failure_not_crash
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      run_if: ->(_) { raise "predicate boom" }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call

    assert result.failure?
    assert_equal :a, result.error[:failed_node]
    step_error = result.error[:step_error]
    assert_equal :layer_admission_error, step_error[:code]
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

    trace = result.trace
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
    assert_equal [:failed_node, :step_error], result.error.keys.sort
    assert result.outputs[:ok].success?
  end

  def test_malformed_schedule_surfaces_as_layer_admission_error
    graph = DAG::Graph.new.add_node(:a)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "never") },
      schedule: {not_before: "not-a-date"}))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call

    assert result.failure?
    assert_equal :a, result.error[:failed_node]
    step_error = result.error[:step_error]
    assert_equal :layer_admission_error, step_error[:code]
    assert_match(/layer admission for step a raised/, step_error[:message])
  end

  def test_empty_graph_succeeds
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.success?
    assert_equal({}, result.outputs)
    assert_equal([], result.trace)
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
    assert_equal :workflow_timeout, result.error[:failed_node]
    assert_equal :workflow_timeout, result.error[:step_error][:code]
    assert_equal 0.1, result.error[:step_error][:timeout_seconds]
  end

  def test_workflow_timeout_does_not_fire_when_under_budget
    defn = build_test_workflow(quick: {command: "echo fast"})
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false, timeout: 5).call
    assert result.success?
    assert_equal "fast", result.outputs[:quick].value
  end

  def test_workflow_timeout_nil_means_no_timeout
    defn = build_test_workflow(a: {command: "echo a"})
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false, timeout: nil).call
    assert result.success?
  end

  def test_workflow_timeout_uses_injected_clock_without_sleeping
    fake_clock = Class.new do
      def initialize(times)
        @times = times.dup
      end

      def wall_now = Time.utc(2026, 4, 14, 0, 0, 0)

      def monotonic_now
        @times.shift || @times.last || 0.0
      end
    end.new([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0])

    defn = build_test_workflow(
      first: {type: :ruby, callable: ->(_) { DAG::Success.new(value: "done") }},
      second: {type: :ruby, depends_on: [:first], callable: ->(_) { DAG::Success.new(value: "never") }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false, timeout: 0.1, clock: fake_clock).call

    assert result.failure?
    assert_equal :workflow_timeout, result.error[:failed_node]
    refute result.outputs.key?(:second)
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

  def test_step_strips_nil_run_if_from_config
    step = DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a", run_if: nil)
    refute step.config.key?(:run_if)
    assert_equal "echo a", step.config[:command]
  end

  def test_step_normalizes_declarative_run_if
    step = DAG::Workflow::Step.new(name: :deploy, type: :exec, command: "echo deploy",
      run_if: {"from" => "tests", "status" => "success"})

    assert_equal({from: :tests, status: :success}, step.config[:run_if])
  end

  def test_step_rejects_malformed_declarative_run_if
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Step.new(name: :deploy, type: :exec, command: "echo deploy", run_if: "bad")
    end

    assert_match(/run_if/, error.message)
    assert_match(/mapping/, error.message)
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
    assert_equal "replaced", result.outputs[:b].value
  end

  def test_definition_replace_step_rewrites_declarative_run_if
    graph = DAG::Graph.new
    %i[build test deploy].each { |n| graph.add_node(n) }
    graph.add_edge(:build, :test)
    graph.add_edge(:test, :deploy)

    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :build, type: :exec, command: "echo built"))
    registry.register(DAG::Workflow::Step.new(name: :test, type: :exec, command: "echo tested"))
    registry.register(DAG::Workflow::Step.new(name: :deploy, type: :exec, command: "echo deploy",
      run_if: {from: :test, status: :success}))

    defn = DAG::Workflow::Definition.new(graph: graph, registry: registry)
    new_step = DAG::Workflow::Step.new(name: :verify, type: :exec, command: "echo verified")
    new_defn = defn.replace_step(:test, new_step)

    # run_if[:from] should be rewritten from :test to :verify
    assert_equal :verify, new_defn.step(:deploy).config[:run_if][:from]

    # Runner should accept the renamed definition without validation error
    runner = DAG::Workflow::Runner.new(new_defn.graph, new_defn.registry, parallel: false)
    result = runner.call
    assert result.success?
  end

  def test_definition_replace_step_leaves_unrelated_run_if_intact
    graph = DAG::Graph.new
    %i[a b c].each { |n| graph.add_node(n) }
    graph.add_edge(:a, :b)
    graph.add_edge(:a, :c)

    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :exec, command: "echo b"))
    registry.register(DAG::Workflow::Step.new(name: :c, type: :exec, command: "echo c",
      run_if: {from: :a, status: :success}))

    defn = DAG::Workflow::Definition.new(graph: graph, registry: registry)
    new_step = DAG::Workflow::Step.new(name: :x, type: :exec, command: "echo x")
    new_defn = defn.replace_step(:b, new_step)

    # c's run_if references :a (not :b), so it should be unchanged
    assert_equal :a, new_defn.step(:c).config[:run_if][:from]
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
