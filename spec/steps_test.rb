# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "minitest/mock"

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

  def test_exec_timeout_kill_returns_early_when_term_succeeds
    # Process traps SIGTERM and exits immediately. With the polling kill,
    # the parent reaps within KILL_GRACE_SECONDS without escalating to KILL.
    cmd = "sh -c 'trap \"exit 0\" TERM; sleep 999'"
    result = run_step(:exec, command: cmd, timeout: 1)
    assert result.failure?
    assert_equal :exec_timeout, result.error[:code]
  end

  def test_exec_timeout_escalates_to_kill_when_term_ignored
    # Process ignores SIGTERM. poll_until_dead times out, KILL is sent.
    # Covers the else of `return if poll_until_dead(...)` and the timeout
    # return-false in poll_until_dead.
    cmd = "sh -c 'trap \"\" TERM; sleep 999'"
    result = run_step(:exec, command: cmd, timeout: 1)
    assert result.failure?
    assert_equal :exec_timeout, result.error[:code]
  end

  def test_exec_kills_process_group_on_timeout
    pidfile = temp_path(prefix: "dag_pgroup_test", suffix: "")
    # The shell writes the background child's PID to a file, then sleeps
    # (holding the pipes open) until killed by timeout. The background
    # child redirects its own stdout/stderr so it doesn't hold the pipes,
    # but it shares the process group set by pgroup: true.
    cmd = "sh -c '(sleep 999 >/dev/null 2>/dev/null & echo $! > #{pidfile}; sleep 999)'"
    result = run_step(:exec, command: cmd, timeout: 1)

    assert result.failure?
    assert_equal :exec_timeout, result.error[:code]

    # If the pidfile was written, verify the background child was killed
    # by the process-group signal.
    if File.exist?(pidfile)
      sleep 0.2
      bg_pid = File.read(pidfile).strip.to_i
      alive = begin
        Process.kill(0, bg_pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
      refute alive, "background child #{bg_pid} should have been killed"
    end
  ensure
    File.delete(pidfile) if pidfile && File.exist?(pidfile)
  end

  def test_exec_returns_failure_when_child_reaped_externally
    # Simulate a host SIGCHLD reaper (Puma/Sidekiq) by stubbing waitpid2
    # to raise ECHILD. stdout/stderr have already been drained.
    Process.stub(:waitpid2, ->(_pid) { raise Errno::ECHILD }) do
      result = run_step(:exec, command: "echo hello")
      assert result.failure?
      assert_equal :exec_status_unavailable, result.error[:code]
      assert_equal "echo hello", result.error[:command]
      assert_equal "hello", result.error[:stdout]
    end
  ensure
    begin
      Process.waitall
    rescue
      # nothing to reap
    end
  end

  def test_exec_returns_failure_on_nil_command
    result = run_step(:exec)
    assert result.failure?
    assert_equal :exec_no_command, result.error[:code]
    assert_match(/no :command/, result.error[:message])
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
    assert_equal :ruby_script_not_found, result.error[:code]
    assert_match(/not found/, result.error[:message])
    assert_equal "/nonexistent/script.rb", result.error[:path]
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
    assert_equal :file_read_not_found, result.error[:code]
    assert_match(/not found/, result.error[:message])
    assert_equal "/nonexistent/file.txt", result.error[:path]
  end

  def test_file_read_fails_without_path
    result = run_step(:file_read)
    assert result.failure?
    assert_equal :file_read_no_path, result.error[:code]
    assert_match(/no :path/, result.error[:message])
  end

  # --- FileWrite ---

  def test_file_write_creates_file
    path = temp_path(prefix: "dag_test_write")
    result = run_step(:file_write, path: path, content: "written by dag")

    assert result.success?
    assert_equal "written by dag", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_appends_in_append_mode
    path = temp_path(prefix: "dag_test_append")
    File.write(path, "first\n")

    run_step(:file_write, path: path, content: "second\n", mode: "a")

    assert_equal "first\nsecond\n", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_uses_input_when_no_content
    path = temp_path(prefix: "dag_test_input")

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
    assert_equal :file_write_no_path, result.error[:code]
    assert_match(/no :path/, result.error[:message])
  end

  def test_file_write_multi_dep_without_from_returns_failure
    path = temp_path(prefix: "dag_test_multidep")
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {a: "foo", b: "bar"})

    assert result.failure?
    assert_equal :file_write_ambiguous_input, result.error[:code]
    assert_match(/multiple upstream deps/, result.error[:message])
    assert_equal [:a, :b], result.error[:input_keys]
    refute File.exist?(path), "should not have written anything"
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_multi_dep_with_from_writes_selected_value
    path = temp_path(prefix: "dag_test_from")
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path, from: :b)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {a: "foo", b: "bar"})

    assert result.success?
    assert_equal "bar", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_from_with_unknown_key_returns_failure
    path = temp_path(prefix: "dag_test_from_unknown")
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path, from: :missing)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {a: "foo"})

    assert result.failure?
    assert_equal :file_write_missing_from_input, result.error[:code]
    assert_match(/no such input/, result.error[:message])
    assert_equal :missing, result.error[:from]
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_content_wins_over_inputs
    path = temp_path(prefix: "dag_test_content_wins")
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path, content: "explicit")
    result = DAG::Workflow::Steps.build(:file_write).call(step, {a: "from_a", b: "from_b"})

    assert result.success?
    assert_equal "explicit", File.read(path)
  ensure
    File.delete(path) if File.exist?(path)
  end

  def test_file_write_zero_dep_no_content_returns_failure
    path = temp_path(prefix: "dag_test_zerodep")
    step = DAG::Workflow::Step.new(name: :write, type: :file_write, path: path)
    result = DAG::Workflow::Steps.build(:file_write).call(step, {})

    assert result.failure?
    assert_equal :file_write_no_content, result.error[:code]
    assert_match(/no content/, result.error[:message])
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
    assert_equal :ruby_callable_raised, result.error[:code]
    assert_match(/boom/, result.error[:message])
    assert_equal "RuntimeError", result.error[:error_class]
  end

  def test_ruby_fails_without_callable
    result = run_step(:ruby)
    assert result.failure?
    assert_equal :ruby_no_callable, result.error[:code]
    assert_match(/no :callable/, result.error[:message])
  end

  # --- Step is pure data ---
  #
  # Construction is always cheap and silent, regardless of config shape.

  def test_step_construction_is_silent_for_simple_config
    _, stderr = capture_io do
      DAG::Workflow::Step.new(name: :test, type: :exec, command: "echo hi", timeout: 30)
    end
    assert_empty stderr
  end

  def test_step_construction_is_silent_for_ruby_callable
    _, stderr = capture_io do
      DAG::Workflow::Step.new(name: :test, type: :ruby, callable: -> { "hi" })
    end
    assert_empty stderr
  end

  # --- Deep freeze ---

  def test_step_config_nested_array_is_frozen
    step = DAG::Workflow::Step.new(name: :test, type: :exec, args: ["a", "b"])
    assert_raises(FrozenError) { step.config[:args] << "c" }
    assert_raises(FrozenError) { step.config[:args][0] = "z" }
  end

  def test_step_config_nested_hash_is_frozen
    step = DAG::Workflow::Step.new(name: :test, type: :exec, env: {"FOO" => "bar"})
    assert_raises(FrozenError) { step.config[:env]["BAZ"] = "qux" }
  end

  def test_step_config_deeply_nested_structure_is_frozen
    step = DAG::Workflow::Step.new(name: :test, type: :exec,
      options: {retries: [1, 2, 3], meta: {key: "val"}})
    assert_raises(FrozenError) { step.config[:options][:retries] << 4 }
    assert_raises(FrozenError) { step.config[:options][:meta][:key] = "new" }
  end

  def test_step_config_string_values_are_frozen
    step = DAG::Workflow::Step.new(name: :test, type: :exec, command: +"mutable string")
    assert step.config[:command].frozen?
  end

  def test_step_config_with_lambda_is_still_callable
    called = false
    lam = ->(_) {
      called = true
      DAG::Success.new(value: "ok")
    }
    step = DAG::Workflow::Step.new(name: :test, type: :ruby, callable: lam)
    step.config[:callable].call(nil)
    assert called
  end

  def test_step_does_not_freeze_original_nested_inputs
    args = ["a", "b"]
    env = {"FOO" => "bar"}
    command = +"mutable string"
    callable = ->(_) { DAG::Success.new(value: "ok") }

    DAG::Workflow::Step.new(name: :test, type: :ruby,
      args: args, env: env, command: command, callable: callable)

    refute args.frozen?
    refute env.frozen?
    refute command.frozen?
    refute callable.frozen?
  end

  def test_step_safe_dup_returns_original_on_type_error
    # Custom object whose `dup` raises TypeError — covers safe_dup's rescue.
    weird = Class.new {
      def dup
        raise TypeError, "no dup for you"
      end
    }.new
    step = DAG::Workflow::Step.new(name: :t, type: :exec, weird: weird)
    assert_same weird, step.config[:weird]
  end

  def test_step_handles_cyclic_config_without_stack_overflow
    config = {}
    config[:self] = config

    step = DAG::Workflow::Step.new(name: :test, type: :exec, data: config)

    assert_same step.config[:data], step.config[:data][:self]
    assert step.config[:data].frozen?
  end

  # --- Unknown type ---

  def test_unknown_step_type_raises
    assert_raises(ArgumentError) { DAG::Workflow::Steps.build(:banana) }
  end

  # --- Steps registry public API ---

  def test_steps_registered_predicate
    assert DAG::Workflow::Steps.registered?(:exec)
    refute DAG::Workflow::Steps.registered?(:nonexistent_type)
  end

  def test_steps_freeze_registry_prevents_register
    # Isolate global state: dup the registry into a fresh mutable hash, swap
    # it in, freeze, attempt to register, restore.
    original_registry = DAG::Workflow::Steps.instance_variable_get(:@registry)
    original_frozen = DAG::Workflow::Steps.instance_variable_get(:@frozen)
    begin
      duped = original_registry.transform_values(&:dup)
      DAG::Workflow::Steps.instance_variable_set(:@registry, duped)
      DAG::Workflow::Steps.instance_variable_set(:@frozen, false)
      DAG::Workflow::Steps.freeze_registry!
      error = assert_raises(DAG::Error) do
        DAG::Workflow::Steps.register(:bogus, Class.new)
      end
      assert_match(/registry is frozen/, error.message)
    ensure
      DAG::Workflow::Steps.instance_variable_set(:@registry, original_registry)
      DAG::Workflow::Steps.instance_variable_set(:@frozen, original_frozen)
    end
  end

  # --- ruby_script no path ---

  def test_ruby_script_returns_failure_on_missing_path
    result = run_step(:ruby_script)
    assert result.failure?
    assert_equal :ruby_script_no_path, result.error[:code]
    assert_match(/no :path config/, result.error[:message])
  end

  # --- file_write invalid mode ---

  def test_file_write_rejects_invalid_mode
    with_tempfile("") do |path|
      result = run_step(:file_write, path: path, content: "hi", mode: "x")
      assert result.failure?
      assert_equal :file_write_invalid_mode, result.error[:code]
      assert_equal "x", result.error[:mode]
    end
  end

  # --- file_read IO error path (not ENOENT) ---

  def test_file_read_io_error_when_path_is_directory
    Dir.mktmpdir do |dir|
      result = run_step(:file_read, path: dir)
      assert result.failure?
      assert_equal :file_read_io_error, result.error[:code]
      assert_equal dir, result.error[:path]
    end
  end

  # --- file_write IO error path ---

  def test_file_write_io_error_for_unwritable_target
    result = run_step(:file_write, path: "/nonexistent_dir_xyz/out.txt", content: "hi")
    assert result.failure?
    assert_equal :file_write_io_error, result.error[:code]
  end

  # --- file_write non-Hash input ---

  def test_file_write_writes_non_hash_input_directly
    with_tempfile("") do |path|
      step = DAG::Workflow::Step.new(name: :w, type: :file_write, path: path)
      result = DAG::Workflow::Steps::FileWrite.new.call(step, "raw content")
      assert result.success?
      assert_equal "raw content", File.read(path)
    end
  end

  private

  def run_step(type, **config)
    step = DAG::Workflow::Step.new(name: :test, type: type, **config)
    DAG::Workflow::Steps.build(type).call(step, nil)
  end
end
