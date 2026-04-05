# frozen_string_literal: true

require_relative "test_helper"

class StepsTest < Minitest::Test
  include TestHelpers

  # --- Exec ---

  def test_exec_runs_command_and_returns_stdout
    result = run_step(:exec, command: "echo hello")
    assert result.success?
    assert_equal "hello", result.value
  end

  def test_exec_returns_failure_on_bad_exit
    result = run_step(:exec, command: "exit 1")
    assert result.failure?
    assert_match(/Exit 1/, result.error)
  end

  def test_exec_returns_failure_on_timeout
    result = run_step(:exec, command: "sleep 10", timeout: 1)
    assert result.failure?
    assert_match(/timed out/, result.error)
  end

  def test_exec_returns_failure_on_nil_command
    result = run_step(:exec)
    assert result.failure?
    assert_match(/No command/, result.error)
  end

  # --- Script ---

  def test_script_runs_ruby_file
    with_tempfile("puts 'from script'", suffix: ".rb") do |path|
      result = run_step(:script, path: path)
      assert result.success?
      assert_equal "from script", result.value
    end
  end

  def test_script_returns_failure_for_missing_file
    result = run_step(:script, path: "/nonexistent/script.rb")
    assert result.failure?
    assert_match(/not found/, result.error)
  end

  def test_script_escapes_path_safely
    # Path with spaces should not cause injection
    with_tempfile("puts 'safe'", suffix: ".rb", prefix: "my script ") do |path|
      result = run_step(:script, path: path)
      assert result.success?
      assert_equal "safe", result.value
    end
  end

  def test_script_passes_args_to_script
    with_tempfile("puts ARGV.join(',')", suffix: ".rb") do |path|
      result = run_step(:script, path: path, args: ["hello", "world"])
      assert result.success?
      assert_equal "hello,world", result.value
    end
  end

  def test_script_escapes_args_safely
    with_tempfile("puts ARGV.first", suffix: ".rb") do |path|
      result = run_step(:script, path: path, args: ["safe; echo injected"])
      assert result.success?
      assert_equal "safe; echo injected", result.value
    end
  end

  # --- FileRead ---

  def test_file_read_returns_content
    with_tempfile("test content") do |path|
      result = run_step(:file_read, path: path)
      assert result.success?
      assert_equal "test content", result.value
    end
  end

  def test_file_read_fails_for_missing_file
    result = run_step(:file_read, path: "/nonexistent/file.txt")
    assert result.failure?
    assert_match(/not found/, result.error)
  end

  def test_file_read_fails_without_path
    result = run_step(:file_read)
    assert result.failure?
    assert_match(/No path/, result.error)
  end

  # --- FileWrite ---

  def test_file_write_creates_file
    path = "/tmp/dag_test_write_#{$$}.txt"
    result = run_step(:file_write, path: path, content: "written by dag")

    assert result.success?
    assert_equal "written by dag", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_appends_in_append_mode
    path = "/tmp/dag_test_append_#{$$}.txt"
    File.write(path, "first\n")

    run_step(:file_write, path: path, content: "second\n", mode: "a")

    assert_equal "first\nsecond\n", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_uses_input_when_no_content
    path = "/tmp/dag_test_input_#{$$}.txt"

    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {upstream: "from input"})

    assert result.success?
    assert_equal "from input", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_fails_without_path
    result = run_step(:file_write, content: "hello")
    assert result.failure?
    assert_match(/No path/, result.error)
  end

  # --- Ruby ---

  def test_ruby_executes_callable
    callable = ->(_input) { DAG::Success(42) }
    result = run_step(:ruby, callable: callable)

    assert result.success?
    assert_equal 42, result.value
  end

  def test_ruby_passes_input_to_callable
    callable = ->(input) { DAG::Success("got: #{input}") }

    step = DAG::Workflow::Step.new(name: :test, type: :ruby, callable: callable)
    result = DAG::Workflow::Steps.build(:ruby).call(step, "hello")

    assert_equal "got: hello", result.value
  end

  def test_ruby_catches_exceptions
    callable = ->(_input) { raise "boom" }
    result = run_step(:ruby, callable: callable)

    assert result.failure?
    assert_match(/boom/, result.error)
  end

  def test_ruby_fails_without_callable
    result = run_step(:ruby)
    assert result.failure?
    assert_match(/No callable/, result.error)
  end

  # --- LLM ---

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
    # Single quotes, semicolons, pipes should not cause injection
    result = run_step(:llm, prompt: "test'; rm -rf /; echo '", command: 'echo "$DAG_LLM_PROMPT"')

    assert result.success?
    assert_includes result.value, "test'"
  end

  # --- Step shareability ---

  def test_step_with_simple_config_is_shareable
    step = DAG::Workflow::Step.new(name: :test, type: :exec, command: "echo hi", timeout: 30)
    assert Ractor.shareable?(step)
  end

  def test_step_with_non_shareable_config_raises
    io = StringIO.new
    error = assert_raises(ArgumentError) do
      DAG::Workflow::Step.new(name: :test, type: :exec, command: io)
    end
    assert_match(/non-shareable/, error.message)
  end

  # --- Unknown type ---

  def test_unknown_step_type_raises
    assert_raises(ArgumentError) { DAG::Workflow::Steps.build(:banana) }
  end

  private

  def run_step(type, **config)
    step = DAG::Workflow::Step.new(name: :test, type: type, **config)
    DAG::Workflow::Steps.build(type).call(step, nil)
  end
end
