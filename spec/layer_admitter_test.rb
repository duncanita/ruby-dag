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
    assert_equal [nil, :skipped, :success], partition.immediate_results.map(&:status)
    assert_equal [{name: :fresh, step: definition.registry[:fresh], input: {}, input_keys: [], deadline: 12.0}], captured
    assert_equal :waiting, store.load_run("wf-layer-admitter")[:nodes][[:waiting]][:state]
    assert_equal :failed, store.load_run("wf-layer-admitter")[:nodes][[:expired]][:state]
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
end
