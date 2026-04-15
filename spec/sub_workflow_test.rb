# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class SubWorkflowTest < Minitest::Test
  include TestHelpers

  def test_yaml_sub_workflow_definition_path_executes_child_workflow_from_parent_file
    Dir.mktmpdir("dag-subworkflow") do |dir|
      child_path = File.join(dir, "child.yml")
      File.write(child_path, <<~YAML)
        nodes:
          summarize:
            type: exec
            command: "printf yaml-child"
      YAML

      parent_path = File.join(dir, "parent.yml")
      File.write(parent_path, <<~YAML)
        nodes:
          process:
            type: sub_workflow
            definition_path: child.yml
            output_key: summarize
      YAML

      definition = DAG::Workflow::Loader.from_file(parent_path)
      result = DAG::Workflow::Runner.new(definition, parallel: false).call

      assert result.success?
      assert_equal "yaml-child", result.outputs[:process].value
      assert_includes result.trace.map(&:name), :"process.summarize"
    end
  end

  def test_nested_definition_paths_resolve_relative_to_each_caller_file
    Dir.mktmpdir("dag-subworkflow-nested") do |dir|
      workflows_dir = File.join(dir, "workflows")
      nested_dir = File.join(workflows_dir, "nested")
      FileUtils.mkdir_p(nested_dir)

      File.write(File.join(nested_dir, "grandchild.yml"), <<~YAML)
        nodes:
          summarize:
            type: exec
            command: "printf nested-child"
      YAML

      File.write(File.join(workflows_dir, "child.yml"), <<~YAML)
        nodes:
          nested:
            type: sub_workflow
            definition_path: nested/grandchild.yml
            output_key: summarize
      YAML

      parent_path = File.join(dir, "parent.yml")
      File.write(parent_path, <<~YAML)
        nodes:
          process:
            type: sub_workflow
            definition_path: workflows/child.yml
            output_key: nested
      YAML

      definition = DAG::Workflow::Loader.from_file(parent_path)
      result = DAG::Workflow::Runner.new(definition, parallel: false).call

      assert result.success?
      assert_equal "nested-child", result.outputs[:process].value
      assert_includes result.trace.map(&:name), :"process.nested.summarize"
    end
  end

  def test_sub_workflow_requires_exactly_one_definition_source
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        process: {
          type: :sub_workflow,
          output_key: :done
        }
      )
    end

    assert_match(/exactly one/, error.message)
  end

  def test_sub_workflow_rejects_both_definition_and_definition_path
    child = DAG::Workflow::Loader.from_hash(done: {type: :exec, command: "printf ok"})

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        process: {
          type: :sub_workflow,
          definition: child,
          definition_path: "child.yml",
          output_key: :done
        }
      )
    end

    assert_match(/exactly one/, error.message)
  end

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

  def test_sub_workflow_propagates_waiting_status_and_namespaced_waiting_nodes
    clock = Struct.new(:wall_time, :mono_time) do
      def wall_now = wall_time
      def monotonic_now = mono_time
    end.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)

    child = DAG::Workflow::Loader.from_hash(
      gated: {
        type: :ruby,
        schedule: {not_before: future_time},
        callable: ->(_input) { DAG::Success.new(value: "later") }
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
        depends_on: [:fetch]
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false, clock: clock).call

    assert_equal :waiting, result.status
    assert_equal "hello", result.outputs[:fetch].value
    refute result.outputs.key?(:process)
    assert_equal [[:process, :gated]], result.waiting_nodes
    refute_includes result.trace.map(&:name), :process
    refute_includes result.trace.map(&:name), :"process.gated"
  end

  def test_sub_workflow_propagates_paused_status_without_parent_output
    store = DAG::Workflow::ExecutionStore::MemoryStore.new

    child = DAG::Workflow::Loader.from_hash(
      inner_fetch: {
        type: :ruby,
        resume_key: "inner-fetch-v1",
        callable: ->(_input) do
          store.set_pause_flag(workflow_id: "wf-child-pause", paused: true)
          DAG::Success.new(value: "raw")
        end
      },
      inner_transform: {
        type: :ruby,
        depends_on: [:inner_fetch],
        resume_key: "inner-transform-v1",
        callable: ->(input) { DAG::Success.new(value: input[:inner_fetch].upcase) }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      process: {
        type: :sub_workflow,
        definition: child,
        output_key: :inner_transform,
        resume_key: "process-v1"
      }
    )

    result = DAG::Workflow::Runner.new(parent,
      parallel: false,
      workflow_id: "wf-child-pause",
      execution_store: store).call

    assert_equal :paused, result.status
    assert result.paused?
    refute result.outputs.key?(:process)
    assert_equal [], result.waiting_nodes
    assert_includes result.trace.map(&:name), :"process.inner_fetch"
    refute_includes result.trace.map(&:name), :process
    refute_includes result.trace.map(&:name), :"process.inner_transform"
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

  def test_definition_path_supports_durable_execution_fingerprints_and_child_namespaces
    Dir.mktmpdir("dag-subworkflow-store") do |dir|
      File.write(File.join(dir, "child.yml"), <<~YAML)
        nodes:
          summarize:
            type: exec
            command: "printf stored-child"
      YAML

      parent_path = File.join(dir, "parent.yml")
      File.write(parent_path, <<~YAML)
        nodes:
          process:
            type: sub_workflow
            definition_path: child.yml
            output_key: summarize
            resume_key: process-v1
      YAML

      definition = DAG::Workflow::Loader.from_file(parent_path)
      store = DAG::Workflow::ExecutionStore::MemoryStore.new

      runner = lambda do
        DAG::Workflow::Runner.new(definition,
          parallel: false,
          workflow_id: "wf-yaml-sub",
          execution_store: store)
      end

      first = runner.call.call
      second = runner.call.call
      run = store.load_run("wf-yaml-sub")

      assert first.success?
      assert second.success?
      assert_equal "stored-child", first.outputs[:process].value
      assert_equal "stored-child", second.outputs[:process].value
      assert_includes run[:node_paths], [:process, :summarize]
      assert_equal "stored-child", store.load_output(workflow_id: "wf-yaml-sub", node_path: [:process, :summarize])[:result].value
    end
  end
end
