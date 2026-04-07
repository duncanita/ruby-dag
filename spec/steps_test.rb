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

  def test_exec_returns_structured_failure_on_bad_exit
    result = run_step(:exec, command: "echo fail >&2; exit 42")
    assert result.failure?
    assert_equal :exec_failed, result.error[:code]
    assert_equal 42, result.error[:exit_status]
    assert_equal "echo fail >&2; exit 42", result.error[:command]
    assert_equal "fail", result.error[:stderr]
  end

  def test_exec_returns_structured_failure_on_timeout
    result = run_step(:exec, command: "sleep 10", timeout: 1)
    assert result.failure?
    assert_equal :exec_timeout, result.error[:code]
    assert_equal "sleep 10", result.error[:command]
    assert_equal 1, result.error[:timeout_seconds]
  end

  def test_exec_returns_failure_on_nil_command
    result = run_step(:exec)
    assert result.failure?
    assert_match(/No command/, result.error)
  end

  def test_exec_handles_large_output_without_deadlock
    result = run_step(:exec, command: "ruby -e 'print \"x\" * 100_000'", timeout: 10)
    assert result.success?
    assert_equal 100_000, result.value.length
  end

  def test_exec_array_command_bypasses_shell
    # Shell metacharacters in argv must be passed literally, not interpreted.
    result = run_step(:exec, command: ["echo", "hi; echo evil"])
    assert result.success?
    assert_equal "hi; echo evil", result.value
  end

  def test_exec_array_command_reports_failure
    result = run_step(:exec, command: ["ruby", "-e", "exit 7"])
    assert result.failure?
    assert_equal :exec_failed, result.error[:code]
    assert_equal 7, result.error[:exit_status]
  end

  # --- RubyScript ---

  def test_ruby_script_runs_ruby_file
    with_tempfile("puts 'from script'", suffix: ".rb") do |path|
      result = run_step(:ruby_script, path: path)
      assert result.success?
      assert_equal "from script", result.value
    end
  end

  def test_ruby_script_returns_failure_for_missing_file
    result = run_step(:ruby_script, path: "/nonexistent/script.rb")
    assert result.failure?
    assert_match(/not found/, result.error)
  end

  def test_ruby_script_escapes_path_safely
    with_tempfile("puts 'safe'", suffix: ".rb", prefix: "my script ") do |path|
      result = run_step(:ruby_script, path: path)
      assert result.success?
      assert_equal "safe", result.value
    end
  end

  def test_ruby_script_passes_args_to_script
    with_tempfile("puts ARGV.join(',')", suffix: ".rb") do |path|
      result = run_step(:ruby_script, path: path, args: ["hello", "world"])
      assert result.success?
      assert_equal "hello,world", result.value
    end
  end

  def test_ruby_script_escapes_args_safely
    with_tempfile("puts ARGV.first", suffix: ".rb") do |path|
      result = run_step(:ruby_script, path: path, args: ["safe; echo injected"])
      assert result.success?
      assert_equal "safe; echo injected", result.value
    end
  end

  def test_old_script_type_raises
    assert_raises(ArgumentError) { DAG::Workflow::Steps.build(:script) }
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

  def test_file_write_multi_dep_without_from_returns_failure
    path = "/tmp/dag_test_multidep_#{$$}.txt"
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {a: "foo", b: "bar"})

    assert result.failure?
    assert_match(/multiple upstream deps/, result.error)
    refute File.exist?(path), "should not have written anything"
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_multi_dep_with_from_writes_selected_value
    path = "/tmp/dag_test_from_#{$$}.txt"
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path, from: :b)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {a: "foo", b: "bar"})

    assert result.success?
    assert_equal "bar", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_from_with_unknown_key_returns_failure
    path = "/tmp/dag_test_from_unknown_#{$$}.txt"
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path, from: :missing)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {a: "foo"})

    assert result.failure?
    assert_match(/no such input/, result.error)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_content_wins_over_inputs
    path = "/tmp/dag_test_content_wins_#{$$}.txt"
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path, content: "explicit")
    result = DAG::Workflow::Steps.build(:file_write).call(step, {a: "from_a", b: "from_b"})

    assert result.success?
    assert_equal "explicit", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_zero_dep_no_content_returns_failure
    path = "/tmp/dag_test_zerodep_#{$$}.txt"
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {})

    assert result.failure?
    assert_match(/no content/, result.error)
  ensure
    File.delete(path) if File.exist?(path)
  end

  # --- Ruby ---

  def test_ruby_executes_callable
    callable = ->(_input) { DAG::Success.new(value: 42) }
    result = run_step(:ruby, callable: callable)

    assert result.success?
    assert_equal 42, result.value
  end

  def test_ruby_passes_input_to_callable
    callable = ->(input) { DAG::Success.new(value: "got: #{input}") }

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

  # --- Step is pure data ---
  #
  # Step does not know about Ractors. Construction is always cheap and silent.
  # Ractor preflight (and any "is this shareable?" warning) belongs to the
  # Ractors strategy — see parallel_test.rb for those.

  def test_step_construction_is_silent_for_simple_config
    _, stderr = capture_io do
      DAG::Workflow::Step.new(name: :test, type: :exec, command: "echo hi", timeout: 30)
    end
    assert_empty stderr
  end

  def test_step_construction_is_silent_for_unshareable_config
    _, stderr = capture_io do
      DAG::Workflow::Step.new(name: :test, type: :exec, command: StringIO.new)
    end
    assert_empty stderr
  end

  def test_step_construction_is_silent_for_ruby_callable
    _, stderr = capture_io do
      DAG::Workflow::Step.new(name: :test, type: :ruby, callable: -> { "hi" })
    end
    assert_empty stderr
  end

  def test_step_does_not_expose_ractor_safe_predicate
    step = DAG::Workflow::Step.new(name: :test, type: :exec, command: "echo hi")
    refute_respond_to step, :ractor_safe?
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
