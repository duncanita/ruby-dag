# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SubWorkflowSupportTest < Minitest::Test
  include TestHelpers

  def test_validate_requires_exactly_one_definition_source
    step = DAG::Workflow::Step.new(name: :process, type: :sub_workflow, output_key: :done)

    errors = DAG::Workflow::SubWorkflowSupport.validate(step)

    assert_equal ["Node 'process' type 'sub_workflow' must define exactly one of definition or definition_path"], errors
  end

  def test_validate_rejects_non_string_definition_path
    step = DAG::Workflow::Step.new(name: :process, type: :sub_workflow, definition_path: 123)

    errors = DAG::Workflow::SubWorkflowSupport.validate(step)

    assert_equal ["Node 'process' definition_path must be a String"], errors
  end

  def test_validate_yaml_serializable_accepts_definition_path_only
    step = DAG::Workflow::Step.new(name: :process, type: :sub_workflow, definition_path: "child.yml")

    DAG::Workflow::SubWorkflowSupport.validate_yaml_serializable!(step)
  end

  def test_validate_yaml_serializable_rejects_embedded_definition
    child = DAG::Workflow::Loader.from_hash(done: {type: :exec, command: "printf ok"})
    step = DAG::Workflow::Step.new(name: :process, type: :sub_workflow, definition: child)

    error = assert_raises(DAG::SerializationError) do
      DAG::Workflow::SubWorkflowSupport.validate_yaml_serializable!(step)
    end

    assert_match(/definition_path/, error.message)
  end

  def test_resolve_definition_returns_embedded_definition
    child = DAG::Workflow::Loader.from_hash(done: {type: :exec, command: "printf ok"})
    step = DAG::Workflow::Step.new(name: :process, type: :sub_workflow, definition: child)

    resolved = DAG::Workflow::SubWorkflowSupport.resolve_definition(step)

    assert_instance_of DAG::Workflow::Definition, resolved
    assert_equal child.graph.to_h, resolved.graph.to_h
    assert_equal child.step(:done).type, resolved.step(:done).type
    assert_equal child.step(:done).config[:command], resolved.step(:done).config[:command]
  end

  def test_resolve_definition_loads_path_relative_to_source
    Dir.mktmpdir("dag-subworkflow-support") do |dir|
      child_path = File.join(dir, "child.yml")
      File.write(child_path, <<~YAML)
        nodes:
          done:
            type: exec
            command: "printf ok"
      YAML

      step = DAG::Workflow::Step.new(name: :process, type: :sub_workflow, definition_path: "child.yml")

      resolved = DAG::Workflow::SubWorkflowSupport.resolve_definition(step, source_path: File.join(dir, "parent.yml"))

      assert_instance_of DAG::Workflow::Definition, resolved
      assert_equal :done, resolved.graph.topological_sort.first
    end
  end
end
