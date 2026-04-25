# frozen_string_literal: true

require_relative "test_helper"

class DependencyInputResolverTest < Minitest::Test
  include TestHelpers

  def test_resolve_returns_latest_dependency_values_without_execution_store
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "scan") }},
      consumer: {
        type: :ruby,
        depends_on: [:source],
        callable: ->(input) { DAG::Success.new(value: input[:source]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph,
      execution_store: nil,
      workflow_id: nil,
      root_input: {tenant: "acme"}
    )

    input = resolver.resolve(
      name: :consumer,
      step: definition.registry[:consumer],
      outputs: {source: DAG::Success.new(value: "scan-1")}
    )

    assert_equal({tenant: "acme", source: "scan-1"}, input)
  end

  def test_resolve_local_version_integer_reads_from_execution_store
    store = build_memory_store
    store.begin_run(workflow_id: "wf-r", definition_fingerprint: "fp", node_paths: [[:source]])
    store.save_output(
      workflow_id: "wf-r", node_path: [:source], version: 1,
      result: DAG::Success.new(value: "v1"), reusable: true, superseded: false
    )
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "scan") }},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, version: 1, as: :first}],
        callable: ->(input) { DAG::Success.new(value: input[:first]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: store, workflow_id: "wf-r"
    )

    input = resolver.resolve(
      name: :consumer,
      step: definition.registry[:consumer],
      outputs: {source: DAG::Success.new(value: "ignored-latest")}
    )

    assert_equal({first: "v1"}, input)
  end

  def test_resolve_local_version_all_returns_ordered_values
    store = build_memory_store
    store.begin_run(workflow_id: "wf-all", definition_fingerprint: "fp", node_paths: [[:source]])
    [[2, "b"], [1, "a"], [3, "c"]].each do |version, value|
      store.save_output(
        workflow_id: "wf-all", node_path: [:source], version: version,
        result: DAG::Success.new(value: value), reusable: true, superseded: false
      )
    end
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "scan") }},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, version: :all, as: :history}],
        callable: ->(input) { DAG::Success.new(value: input[:history]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: store, workflow_id: "wf-all"
    )

    input = resolver.resolve(
      name: :consumer,
      step: definition.registry[:consumer],
      outputs: {source: DAG::Success.new(value: "latest")}
    )

    assert_equal(%w[a b c], input[:history])
  end

  def test_resolve_missing_local_version_raises_structured_error
    store = build_memory_store
    store.begin_run(workflow_id: "wf-miss", definition_fingerprint: "fp", node_paths: [[:source]])
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "scan") }},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, version: 7, as: :missing}],
        callable: ->(input) { DAG::Success.new(value: input[:missing]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: store, workflow_id: "wf-miss"
    )

    error = assert_raises(DAG::Workflow::DependencyInputResolver::MissingVersionError) do
      resolver.resolve(
        name: :consumer,
        step: definition.registry[:consumer],
        outputs: {source: DAG::Success.new(value: "latest")}
      )
    end

    assert_equal :source, error.dependency_name
    assert_equal 7, error.version
    assert_match(/version 7/, error.message)
  end

  def test_resolve_versioned_without_execution_store_raises_structured_error
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "scan") }},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, version: 2}],
        callable: ->(input) { DAG::Success.new(value: input[:source]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil
    )

    error = assert_raises(DAG::Workflow::DependencyInputResolver::MissingExecutionStoreError) do
      resolver.resolve(
        name: :consumer,
        step: definition.registry[:consumer],
        outputs: {source: DAG::Success.new(value: "latest")}
      )
    end

    assert_equal :source, error.dependency_name
    assert_equal 2, error.version
  end

  def test_resolve_external_dependency_nil_raises_waiting_with_descriptor
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "pipeline-a", node: :validated_output, version: 2, as: :validated}],
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil,
      cross_workflow_resolver: ->(*_args) {}
    )

    error = assert_raises(DAG::Workflow::DependencyInputResolver::WaitingForDependencyError) do
      resolver.resolve(
        name: :consumer,
        step: definition.registry[:consumer],
        outputs: {}
      )
    end

    assert_equal "pipeline-a", error.workflow_id
    assert_equal :validated_output, error.node_name
    assert_equal 2, error.version
  end

  def test_resolve_external_resolver_exception_is_wrapped_in_resolver_error
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "pipeline-a", node: :validated_output, version: 2, as: :validated}],
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil,
      cross_workflow_resolver: ->(*_args) { raise "boom" }
    )

    error = assert_raises(DAG::Workflow::DependencyInputResolver::ResolverError) do
      resolver.resolve(
        name: :consumer,
        step: definition.registry[:consumer],
        outputs: {}
      )
    end

    assert_equal "pipeline-a", error.workflow_id
    assert_equal :validated_output, error.node_name
    assert_equal 2, error.version
    assert_match(/boom/, error.message)
  end

  def test_resolve_external_without_resolver_raises_missing_cross_workflow_resolver
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "pipeline-a", node: :validated_output, as: :validated}],
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil
    )

    error = assert_raises(DAG::Workflow::DependencyInputResolver::MissingCrossWorkflowResolverError) do
      resolver.resolve(
        name: :consumer,
        step: definition.registry[:consumer],
        outputs: {}
      )
    end

    assert_equal "pipeline-a", error.workflow_id
    assert_equal :validated_output, error.node_name
  end

  def test_invokes_positional_and_keyword_resolver_callables
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "pipeline-a", node: :node_x, version: 2, as: :val}],
        callable: ->(input) { DAG::Success.new(value: input[:val]) }
      }
    )

    captured_positional = nil
    positional = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil,
      cross_workflow_resolver: lambda do |workflow_id, node_name, version|
        captured_positional = [workflow_id, node_name, version]
        "pos"
      end
    )
    positional.resolve(name: :consumer, step: definition.registry[:consumer], outputs: {})
    assert_equal ["pipeline-a", :node_x, 2], captured_positional

    captured_kw = nil
    keyword = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil,
      cross_workflow_resolver: lambda do |workflow_id:, node_name:, version:|
        captured_kw = {workflow_id: workflow_id, node_name: node_name, version: version}
        "kw"
      end
    )
    keyword.resolve(name: :consumer, step: definition.registry[:consumer], outputs: {})
    assert_equal({workflow_id: "pipeline-a", node_name: :node_x, version: 2}, captured_kw)
  end

  def test_input_keys_for_sorts_and_dedups
    definition = build_test_workflow(
      a: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: 1) }},
      b: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: 2) }},
      consumer: {
        type: :ruby,
        depends_on: [
          :a,
          :b,
          {workflow: "external", node: :c, as: :c}
        ],
        callable: ->(input) { DAG::Success.new(value: input) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil,
      root_input: {tenant: "acme"}
    )

    assert_equal %i[a b c tenant],
      resolver.input_keys_for(name: :consumer, step: definition.registry[:consumer])
  end

  def test_callable_input_lazy_loads_external_dependencies
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [
          {workflow: "pipeline-a", node: :costly, as: :costly}
        ],
        callable: ->(input) { DAG::Success.new(value: input[:costly]) }
      }
    )
    resolver_calls = 0
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil,
      cross_workflow_resolver: lambda do |*_args|
        resolver_calls += 1
        "external-value"
      end,
      root_input: {tenant: "acme"}
    )

    lazy_input = resolver.callable_input_for(
      name: :consumer,
      step: definition.registry[:consumer],
      outputs: {},
      statuses: {}
    )

    assert_equal 0, resolver_calls
    assert_equal "acme", lazy_input[:tenant]
    assert_equal 0, resolver_calls

    assert_equal "external-value", lazy_input[:costly]
    assert_equal 1, resolver_calls
    assert_equal "external-value", lazy_input[:costly]
    assert_equal 1, resolver_calls
  end

  def test_callable_input_fetch_and_key_helpers
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "w", node: :ext, as: :ext}],
        callable: ->(input) { DAG::Success.new(value: input[:ext]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil,
      cross_workflow_resolver: ->(*_args) { "ext-value" },
      root_input: {tenant: "acme"}
    )

    lazy = resolver.callable_input_for(
      name: :consumer,
      step: definition.registry[:consumer],
      outputs: {},
      statuses: {}
    )

    assert lazy.key?(:tenant)
    assert lazy.include?(:ext)
    refute lazy.key?(:missing)

    assert_equal "fallback", lazy.fetch(:missing, "fallback")
    assert_equal "default", lazy.fetch(:missing) { "default" }
    assert_raises(KeyError) { lazy.fetch(:missing) }
  end

  def test_condition_context_for_resolves_only_referenced_external_deps
    definition = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [
          {workflow: "w", node: :x, as: :x},
          {workflow: "w", node: :y, as: :y}
        ],
        callable: ->(input) { DAG::Success.new(value: input) }
      }
    )
    resolver_keys = []
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil,
      cross_workflow_resolver: lambda do |_wf, node_name, _v|
        resolver_keys << node_name
        "value-of-#{node_name}"
      end
    )

    context = resolver.condition_context_for(
      name: :consumer,
      step: definition.registry[:consumer],
      outputs: {},
      statuses: {},
      condition: {from: :x, value: {equals: "value-of-x"}}
    )

    assert_equal [:x], resolver_keys
    assert_equal "value-of-x", context[:x][:value]
    refute context.key?(:y)
  end

  def test_callable_input_for_keys_local_aliased_dep_by_input_key
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "scan") }},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, as: :first}],
        callable: ->(input) { DAG::Success.new(value: input[:first]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil
    )

    lazy = resolver.callable_input_for(
      name: :consumer,
      step: definition.registry[:consumer],
      outputs: {source: DAG::Success.new(value: "scan-1")},
      statuses: {source: :success}
    )

    assert_equal "scan-1", lazy[:first]
    assert lazy.key?(:first)
    refute lazy.key?(:source)
  end

  def test_condition_context_for_keys_local_aliased_dep_by_input_key
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "scan") }},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, as: :first}],
        callable: ->(input) { DAG::Success.new(value: input[:first]) }
      }
    )
    resolver = DAG::Workflow::DependencyInputResolver.new(
      graph: definition.graph, execution_store: nil, workflow_id: nil
    )

    context = resolver.condition_context_for(
      name: :consumer,
      step: definition.registry[:consumer],
      outputs: {source: DAG::Success.new(value: "scan-1")},
      statuses: {source: :success}
    )

    assert_equal({value: "scan-1", status: :success}, context[:first])
    refute context.key?(:source)
  end
end
