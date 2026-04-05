# frozen_string_literal: true

require_relative "../test_helper"
require "dag/ext/llm"

class LLMExtensionTest < Minitest::Test
  def test_llm_fails_without_prompt
    result = run_step(:llm, command: "echo test")
    assert result.failure?
    assert_match(/No prompt/, result.error)
  end

  def test_llm_fails_without_command
    result = run_step(:llm, prompt: "hello")
    assert result.failure?
    assert_match(/No command/, result.error)
  end

  def test_llm_passes_prompt_via_env_var
    result = run_step(:llm, prompt: "hello {{input}}", command: 'echo "$DAG_LLM_PROMPT"')

    assert result.success?
    assert_equal "hello", result.value
  end

  def test_llm_interpolates_input_in_prompt
    step = DAG::Workflow::Step.new(name: :test, type: :llm, prompt: "say {{input}}", command: 'echo "$DAG_LLM_PROMPT"')
    result = DAG::Workflow::Steps.build(:llm).call(step, "world")

    assert_equal "say world", result.value
  end

  def test_llm_prompt_with_shell_metacharacters_is_safe
    result = run_step(:llm, prompt: "test'; rm -rf /; echo '", command: 'echo "$DAG_LLM_PROMPT"')

    assert result.success?
    assert_includes result.value, "test'"
  end

  def test_llm_registered_after_require
    assert DAG::Workflow::Steps::REGISTRY.key?(:llm)
  end

  def test_llm_in_yaml_types_after_require
    assert_includes DAG::Workflow::Loader::YAML_TYPES, "llm"
  end

  def test_loads_llm_from_yaml
    defn = DAG::Workflow::Loader.from_yaml(<<~YAML)
      name: test
      nodes:
        ask:
          type: llm
          prompt: "hello"
          command: "echo test"
    YAML

    assert_equal :llm, defn.step(:ask).type
  end

  private

  def run_step(type, **config)
    step = DAG::Workflow::Step.new(name: :test, type: type, **config)
    DAG::Workflow::Steps.build(type).call(step, nil)
  end
end
