# frozen_string_literal: true

require_relative "test_helper"

class SubWorkflowTest < Minitest::Test
  include TestHelpers

  def test_programmatic_sub_workflow_returns_child_leaf_outputs_and_namespaced_trace
    child = DAG::Workflow::Loader.from_hash(
      analyze: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: input[:raw].upcase) }
      },
      summarize: {
        type: :ruby,
        depends_on: [:analyze],
        callable: ->(input) { DAG::Success.new(value: "#{input[:analyze]}!") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch],
        input_mapping: {fetch: :raw}
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false).call

    assert result.success?
    assert_equal({summarize: "HELLO!"}, result.outputs[:process].value)
    assert_includes result.trace.map(&:name), :"process.analyze"
    assert_includes result.trace.map(&:name), :"process.summarize"
  end

  def test_sub_workflow_output_key_returns_selected_leaf_value
    child = DAG::Workflow::Loader.from_hash(
      analyze: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: input[:raw].upcase) }
      },
      summarize: {
        type: :ruby,
        depends_on: [:analyze],
        callable: ->(input) { DAG::Success.new(value: "#{input[:analyze]}!") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch],
        input_mapping: {fetch: :raw},
        output_key: :summarize
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false).call

    assert result.success?
    assert_equal "HELLO!", result.outputs[:process].value
  end

  def test_sub_workflow_rejects_non_leaf_output_key
    child = DAG::Workflow::Loader.from_hash(
      analyze: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: input[:raw].upcase) }
      },
      summarize: {
        type: :ruby,
        depends_on: [:analyze],
        callable: ->(input) { DAG::Success.new(value: "#{input[:analyze]}!") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch],
        input_mapping: {fetch: :raw},
        output_key: :analyze
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false).call

    assert result.failure?
    assert_equal :process, result.error[:failed_node]
    assert_equal :sub_workflow_invalid_output_key, result.error[:step_error][:code]
  end

  def test_sub_workflow_uses_parent_context_and_execution_store_namespace
    child_calls = 0
    child = DAG::Workflow::Loader.from_hash(
      inner_fetch: {
        type: :ruby,
        resume_key: "inner-fetch-v1",
        callable: ->(input, context) do
          child_calls += 1
          DAG::Success.new(value: "#{input[:raw]}#{context[:suffix]}")
        end
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        resume_key: "fetch-v1",
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch],
        input_mapping: {fetch: :raw},
        output_key: :inner_fetch,
        resume_key: "process-v1"
      }
    )

    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    runner = lambda do
      DAG::Workflow::Runner.new(parent,
        parallel: false,
        context: {suffix: "!"},
        workflow_id: "wf-sub",
        execution_store: store)
    end

    first = runner.call.call
    second = runner.call.call
    run = store.load_run("wf-sub")

    assert first.success?
    assert second.success?
    assert_equal "hello!", first.outputs[:process].value
    assert_equal "hello!", second.outputs[:process].value
    assert_equal 1, child_calls
    assert_includes run[:node_paths], [:process, :inner_fetch]
    assert_equal "hello!", store.load_output(workflow_id: "wf-sub", node_path: [:process, :inner_fetch])[:result].value
  end
end
