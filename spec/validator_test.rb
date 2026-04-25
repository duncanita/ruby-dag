# frozen_string_literal: true

require_relative "test_helper"

class ValidatorTest < Minitest::Test
  include TestHelpers

  Validator = DAG::Workflow::Validator
  ValidationReport = DAG::Workflow::ValidationReport

  def test_valid_workflow_with_no_run_if
    defn = build_test_workflow(a: {}, b: {depends_on: [:a]})
    report = Validator.validate(defn.graph, defn.registry)
    assert report.valid?
    assert_empty report.errors
  end

  def test_valid_workflow_with_declarative_run_if
    defn = build_test_workflow(
      a: {},
      b: {depends_on: [:a], run_if: {from: :a, status: :success}}
    )
    report = Validator.validate(defn.graph, defn.registry)
    assert report.valid?
  end

  def test_valid_workflow_with_callable_run_if
    defn = build_test_workflow(
      a: {},
      b: {depends_on: [:a], run_if: ->(_) { true }}
    )
    report = Validator.validate(defn.graph, defn.registry)
    assert report.valid?
  end

  def test_invalid_run_if_referencing_non_dependency
    graph = DAG::Graph.new
    %i[a b c].each { |n| graph.add_node(n) }
    graph.add_edge(:a, :c)

    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :exec, command: "echo b"))
    registry.register(DAG::Workflow::Step.new(name: :c, type: :exec, command: "echo c",
      run_if: {from: :b, status: :success}))

    report = Validator.validate(graph, registry)
    refute report.valid?
    assert_equal 1, report.errors.size
    assert_match(/\bb\b/, report.errors.first)
  end

  def test_collects_multiple_errors
    graph = DAG::Graph.new
    %i[a b c].each { |n| graph.add_node(n) }

    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :exec, command: "echo b",
      run_if: {from: :a, status: :success}))
    registry.register(DAG::Workflow::Step.new(name: :c, type: :exec, command: "echo c",
      run_if: {from: :a, status: :success}))

    report = Validator.validate(graph, registry)
    refute report.valid?
    assert_equal 2, report.errors.size
  end

  def test_validate_bang_raises_on_invalid
    graph = DAG::Graph.new
    %i[a b].each { |n| graph.add_node(n) }

    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo a"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :exec, command: "echo b",
      run_if: {from: :a, status: :success}))

    assert_raises(DAG::ValidationError) { Validator.validate!(graph, registry) }
  end

  def test_validate_bang_returns_graph_and_registry_on_valid
    defn = build_test_workflow(a: {}, b: {depends_on: [:a]})
    result = Validator.validate!(defn.graph, defn.registry)
    assert_equal [defn.graph, defn.registry], result
  end

  def test_rejects_duplicate_effective_dependency_input_keys
    defn = build_test_workflow(
      source_a: {},
      source_b: {},
      merge: {
        type: :ruby,
        depends_on: [
          {from: :source_a, as: :shared},
          {from: :source_b, as: :shared}
        ],
        callable: ->(input) { DAG::Success.new(value: input) }
      }
    )

    report = Validator.validate(defn.graph, defn.registry)

    refute report.valid?
    assert_match(/duplicate effective input key/i, report.errors.first)
    assert_match(/shared/, report.errors.first)
  end

  def test_rejects_invalid_dependency_version_selector
    defn = build_test_workflow(
      source: {},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, version: 0}],
        callable: ->(input) { DAG::Success.new(value: input) }
      }
    )

    report = Validator.validate(defn.graph, defn.registry)

    refute report.valid?
    assert_match(/invalid version/i, report.errors.first)
    assert_match(/positive Integer/, report.errors.first)
  end

  def test_rejects_duplicate_effective_input_keys_across_local_and_external_dependencies
    defn = build_test_workflow(
      source: {},
      consumer: {
        type: :ruby,
        depends_on: [
          {from: :source, as: :shared},
          {workflow: "pipeline-a", node: :validated_output, as: :shared}
        ],
        callable: ->(input) { DAG::Success.new(value: input) }
      }
    )

    report = Validator.validate(defn.graph, defn.registry)

    refute report.valid?
    assert_match(/duplicate effective input key/i, report.errors.first)
    assert_match(/shared/, report.errors.first)
  end

  def test_allows_declarative_run_if_to_reference_external_dependency_alias
    defn = build_test_workflow(
      consumer: {
        type: :ruby,
        depends_on: [{workflow: "pipeline-a", node: :validated_output, as: :validated}],
        run_if: {from: :validated, value: {equals: "ready"}},
        callable: ->(input) { DAG::Success.new(value: input[:validated]) }
      }
    )

    report = Validator.validate(defn.graph, defn.registry)

    assert report.valid?
    assert_empty report.errors
  end

  def test_skips_nodes_not_in_registry
    graph = DAG::Graph.new
    graph.add_node(:a)

    registry = DAG::Workflow::Registry.new
    # node :a not registered — should not blow up
    report = Validator.validate(graph, registry)
    assert report.valid?
  end

  def test_validation_report_frozen_errors
    report = ValidationReport.new(errors: ["err"])
    assert report.errors.frozen?
  end

  def test_allows_declarative_run_if_to_reference_local_dependency_alias
    defn = build_test_workflow(
      source: {},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, as: :first}],
        run_if: {from: :first, value: {equals: "ready"}},
        callable: ->(input) { DAG::Success.new(value: input[:first]) }
      }
    )

    report = Validator.validate(defn.graph, defn.registry)

    assert report.valid?
    assert_empty report.errors
  end

  def test_rejects_declarative_run_if_referencing_local_dependency_raw_name_when_aliased
    defn = build_test_workflow(
      source: {},
      consumer: {
        type: :ruby,
        depends_on: [{from: :source, as: :first}],
        run_if: {from: :source, value: {equals: "ready"}},
        callable: ->(input) { DAG::Success.new(value: input[:first]) }
      }
    )

    report = Validator.validate(defn.graph, defn.registry)

    refute report.valid?
    assert_equal 1, report.errors.size
    assert_match(/\bsource\b/, report.errors.first)
    assert_match(/\bfirst\b/, report.errors.first)
  end
end
