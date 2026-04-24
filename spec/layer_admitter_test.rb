# frozen_string_literal: true

require_relative "test_helper"

class LayerAdmitterTest < Minitest::Test
  include TestHelpers

  def test_call_partitions_waiting_expired_skipped_reused_and_runnable_steps
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))
    store = build_memory_store
    definition = build_test_workflow(
      waiting: {
        type: :ruby,
        schedule: {not_before: Time.utc(2026, 4, 15, 10, 0, 0)},
        callable: ->(_input) { DAG::Success.new(value: "later") }
      },
      expired: {
        type: :ruby,
        schedule: {not_after: Time.utc(2026, 4, 15, 8, 0, 0)},
        callable: ->(_input) { DAG::Success.new(value: "too-late") }
      },
      skipped: {
        type: :ruby,
        run_if: ->(_ctx) { false },
        callable: ->(_input) { DAG::Success.new(value: "skip") }
      },
      reused: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "fresh") }
      },
      fresh: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "fresh") }
      }
    )

    store.begin_run(
      workflow_id: "wf-layer-admitter",
      definition_fingerprint: "fp-layer-admitter",
      node_paths: [[:waiting], [:expired], [:skipped], [:reused], [:fresh]]
    )
    store.save_output(
      workflow_id: "wf-layer-admitter",
      node_path: [:reused],
      version: 1,
      result: DAG::Success.new(value: "cached"),
      reusable: true,
      superseded: false,
      saved_at: clock.wall_now
    )

    persistence = DAG::Workflow::ExecutionPersistence.new(
      execution_store: store,
      workflow_id: "wf-layer-admitter",
      registry: definition.registry,
      clock: clock
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph,
      execution_store: store,
      workflow_id: "wf-layer-admitter"
    )
    captured = []

    admitter = DAG::Workflow::LayerAdmitter.new(
      graph: definition.graph,
      registry: definition.registry,
      clock: clock,
      execution_persistence: persistence,
      dependency_input_resolver: resolver,
      root_input: {},
      task_builder: lambda do |name:, step:, input:, input_keys:, deadline:|
        captured << {name: name, step: step, input: input, input_keys: input_keys, deadline: deadline}
        Data.define(:name, :step, :input, :input_keys).new(name: name, step: step, input: input, input_keys: input_keys)
      end
    )

    partition = admitter.call(layer: [:waiting, :expired, :skipped, :reused, :fresh], previous_outputs: {}, statuses: {}, deadline: 12.0)

    assert_equal [[:waiting]], partition.waiting_nodes
    assert_equal %i[fresh], partition.runnable.map(&:name)
    assert_equal %i[expired skipped reused], partition.immediate_results.map(&:name)
    assert_equal [:failure, :skipped, :success], partition.immediate_results.map(&:status)
    assert_equal [{name: :fresh, step: definition.registry[:fresh], input: {}, input_keys: [], deadline: 12.0}], captured
    assert_equal :waiting, store.load_run("wf-layer-admitter")[:nodes][[:waiting]][:state]
    assert_equal :failed, store.load_run("wf-layer-admitter")[:nodes][[:expired]][:state]
  end

  def test_call_rejects_impossible_schedule_window_as_failure_not_waiting
    # Regression: not_before > not_after must not park in :waiting state.
    # It should immediately fail with :invalid_schedule_window.
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))
    store = build_memory_store
    definition = build_test_workflow(
      impossible: {
        type: :ruby,
        schedule: {
          not_before: Time.utc(2026, 4, 15, 10, 0, 0), # > not_after
          not_after: Time.utc(2026, 4, 15, 8, 0, 0)   # < not_before
        },
        callable: ->(_input) { DAG::Success.new(value: "never") }
      }
    )

    store.begin_run(
      workflow_id: "wf-impossible-window",
      definition_fingerprint: "fp-impossible-window",
      node_paths: [[:impossible]]
    )

    persistence = DAG::Workflow::ExecutionPersistence.new(
      execution_store: store,
      workflow_id: "wf-impossible-window",
      registry: definition.registry,
      clock: clock
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph,
      execution_store: store,
      workflow_id: "wf-impossible-window"
    )

    admitter = DAG::Workflow::LayerAdmitter.new(
      graph: definition.graph,
      registry: definition.registry,
      clock: clock,
      execution_persistence: persistence,
      dependency_input_resolver: resolver,
      root_input: {},
      task_builder: ->(**_kwargs) { flunk "task_builder should not be called for impossible window" }
    )

    partition = admitter.call(layer: [:impossible], previous_outputs: {}, statuses: {}, deadline: nil)

    # The step must not be put in waiting_nodes.
    assert_empty partition.waiting_nodes, "impossible window must not enter :waiting state"
    # Must appear in immediate_results as a failure.
    assert_equal [:impossible], partition.immediate_results.map(&:name)
    assert_equal [:failure], partition.immediate_results.map(&:status)
    # The stored error must have the correct code.
    error = partition.immediate_results.first.result.error
    assert_equal :invalid_schedule_window, error[:code]
    assert_match(/not_before.*after.*not_after/, error[:message])
    # The execution store must have recorded :failed state, not :waiting.
    run_record = store.load_run("wf-impossible-window")
    assert_equal :failed, run_record[:nodes][[:impossible]][:state]
    assert_equal :invalid_schedule_window, run_record[:nodes][[:impossible]][:reason][:code]
  end

  def test_call_translates_missing_execution_store_into_immediate_failure
    definition = build_test_workflow(
      source: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "scan") }
      },
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, version: 2, as: :historical}],
        callable: ->(input) { DAG::Success.new(value: input[:historical]) }
      }
    )

    admitter = DAG::Workflow::LayerAdmitter.new(
      graph: definition.graph,
      registry: definition.registry,
      clock: build_clock,
      execution_persistence: DAG::Workflow::ExecutionPersistence.new(
        execution_store: nil,
        workflow_id: nil,
        registry: definition.registry,
        clock: build_clock
      ),
      dependency_input_resolver: DAG::Workflow::DependencyInputResolver.new(
        graph: definition.graph,
        execution_store: nil,
        workflow_id: nil
      ),
      root_input: {},
      task_builder: ->(**_kwargs) { flunk "task_builder should not be called" }
    )

    partition = admitter.call(
      layer: [:consumer],
      previous_outputs: {source: DAG::Success.new(value: "scan")},
      statuses: {source: :success},
      deadline: nil
    )

    assert_empty partition.runnable
    assert_empty partition.waiting_nodes
    assert_equal 1, partition.immediate_results.size
    assert_equal :consumer, partition.immediate_results.first.name
    assert_equal :versioned_dependency_requires_execution_store, partition.immediate_results.first.result.error[:code]
  end

  def test_call_marks_cross_workflow_dependency_waiting_when_resolver_returns_nil
    store = build_memory_store
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "pipeline-a", node: :validated_output, version: 2, as: :validated}],
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )

    store.begin_run(
      workflow_id: "wf-layer-waiting",
      definition_fingerprint: "fp-layer-waiting",
      node_paths: [[:consumer]]
    )

    admitter = DAG::Workflow::LayerAdmitter.new(
      graph: definition.graph,
      registry: definition.registry,
      clock: build_clock,
      execution_persistence: DAG::Workflow::ExecutionPersistence.new(
        execution_store: store,
        workflow_id: "wf-layer-waiting",
        registry: definition.registry,
        clock: build_clock
      ),
      dependency_input_resolver: DAG::Workflow::DependencyInputResolver.new(
        graph: definition.graph,
        execution_store: store,
        workflow_id: "wf-layer-waiting",
        cross_workflow_resolver: ->(*_args) {}
      ),
      root_input: {},
      task_builder: ->(**_kwargs) { flunk "task_builder should not be called" }
    )

    partition = admitter.call(layer: [:consumer], previous_outputs: {}, statuses: {}, deadline: nil)

    assert_empty partition.runnable
    assert_empty partition.immediate_results
    assert_equal [[:consumer]], partition.waiting_nodes
    assert_equal :waiting, store.load_run("wf-layer-waiting")[:nodes][[:consumer]][:state]
  end

  def test_call_checks_not_before_before_run_if_or_external_resolution
    store = build_memory_store
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        schedule: {not_before: Time.utc(2026, 4, 15, 10, 0, 0)},
        run_if: ->(_input) { flunk "run_if should not be evaluated before not_before is reached" },
        depends_on: [{workflow: "pipeline-a", node: :validated_output, version: 2, as: :validated}],
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )

    store.begin_run(
      workflow_id: "wf-layer-not-before",
      definition_fingerprint: "fp-layer-not-before",
      node_paths: [[:consumer]]
    )

    resolver_calls = 0
    admitter = DAG::Workflow::LayerAdmitter.new(
      graph: definition.graph,
      registry: definition.registry,
      clock: clock,
      execution_persistence: DAG::Workflow::ExecutionPersistence.new(
        execution_store: store,
        workflow_id: "wf-layer-not-before",
        registry: definition.registry,
        clock: clock
      ),
      dependency_input_resolver: DAG::Workflow::DependencyInputResolver.new(
        graph: definition.graph,
        execution_store: store,
        workflow_id: "wf-layer-not-before",
        cross_workflow_resolver: lambda do |*_args|
          resolver_calls += 1
          raise "resolver should not run before not_before is reached"
        end
      ),
      root_input: {},
      task_builder: ->(**_kwargs) { flunk "task_builder should not be called" }
    )

    partition = admitter.call(layer: [:consumer], previous_outputs: {}, statuses: {}, deadline: nil)

    assert_equal 0, resolver_calls
    assert_empty partition.runnable
    assert_empty partition.immediate_results
    assert_equal [[:consumer]], partition.waiting_nodes
    assert_equal :waiting, store.load_run("wf-layer-not-before")[:nodes][[:consumer]][:state]
  end

  def test_call_skips_before_resolving_missing_cross_workflow_dependency_when_run_if_is_false
    store = build_memory_store
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        run_if: ->(_ctx) { false },
        depends_on: [{workflow: "pipeline-a", node: :validated_output, version: 2, as: :validated}],
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )

    store.begin_run(
      workflow_id: "wf-layer-skip-first",
      definition_fingerprint: "fp-layer-skip-first",
      node_paths: [[:consumer]]
    )

    resolver_calls = 0
    admitter = DAG::Workflow::LayerAdmitter.new(
      graph: definition.graph,
      registry: definition.registry,
      clock: build_clock,
      execution_persistence: DAG::Workflow::ExecutionPersistence.new(
        execution_store: store,
        workflow_id: "wf-layer-skip-first",
        registry: definition.registry,
        clock: build_clock
      ),
      dependency_input_resolver: DAG::Workflow::DependencyInputResolver.new(
        graph: definition.graph,
        execution_store: store,
        workflow_id: "wf-layer-skip-first",
        cross_workflow_resolver: lambda do |*_args|
          resolver_calls += 1
          nil
        end
      ),
      root_input: {},
      task_builder: ->(**_kwargs) { flunk "task_builder should not be called" }
    )

    partition = admitter.call(layer: [:consumer], previous_outputs: {}, statuses: {}, deadline: nil)

    assert_equal 0, resolver_calls
    assert_empty partition.runnable
    assert_empty partition.waiting_nodes
    assert_equal [:consumer], partition.immediate_results.map(&:name)
    assert_equal [:skipped], partition.immediate_results.map(&:status)
  end

  def test_call_uses_effective_versioned_dependency_values_for_declarative_run_if_context
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
      consumer: {
        type: :ruby,
        resume_key: "consumer-v1",
        schedule: {ttl: 1},
        depends_on: [{from: :source, version: 1, as: :historical}],
        run_if: {from: :source, value: {equals: "scan-1"}},
        callable: ->(input) { DAG::Success.new(value: input[:historical]) }
      }
    )

    first = DAG::Workflow::Runner.new(
      definition,
      parallel: false,
      clock: clock,
      execution_store: store,
      workflow_id: "wf-versioned-run-if"
    ).call
    assert_equal "scan-1", first.outputs[:consumer].value

    clock.advance(2)

    second = DAG::Workflow::Runner.new(
      definition,
      parallel: false,
      clock: clock,
      execution_store: store,
      workflow_id: "wf-versioned-run-if"
    ).call

    assert_equal :completed, second.status
    assert_equal "scan-1", second.outputs[:consumer].value
    consumer_entries = second.trace.select { |entry| entry.name == :consumer }
    assert_equal [:success], consumer_entries.map(&:status)
  end

  def test_call_uses_effective_versioned_dependency_values_for_callable_run_if_context
    store = build_memory_store
    clock = build_clock
    source_calls = 0
    consumer_calls = 0
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
      consumer: {
        type: :ruby,
        resume_key: "consumer-v1",
        schedule: {ttl: 1},
        depends_on: [{from: :source, version: 1, as: :historical}],
        run_if: ->(input) { input[:source] == "scan-1" },
        callable: ->(input) do
          consumer_calls += 1
          DAG::Success.new(value: input[:historical])
        end
      }
    )

    first = DAG::Workflow::Runner.new(
      definition,
      parallel: false,
      clock: clock,
      execution_store: store,
      workflow_id: "wf-callable-versioned-run-if"
    ).call
    assert_equal "scan-1", first.outputs[:consumer].value

    clock.advance(2)

    second = DAG::Workflow::Runner.new(
      definition,
      parallel: false,
      clock: clock,
      execution_store: store,
      workflow_id: "wf-callable-versioned-run-if"
    ).call

    assert_equal :completed, second.status
    assert_equal 2, consumer_calls
    assert_equal "scan-1", second.outputs[:consumer].value
    consumer_entries = second.trace.select { |entry| entry.name == :consumer }
    assert_equal [:success], consumer_entries.map(&:status)
  end
end
