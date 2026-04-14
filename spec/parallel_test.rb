# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class ParallelTest < Minitest::Test
  include TestHelpers

  # 1. Callback ordering in parallel layers: both names present, order non-deterministic
  def test_parallel_callbacks_both_fire
    finished = []

    defn = build_test_workflow(a: {}, b: {})

    DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true,
      on_step_finish: ->(name, _result) { finished << name }).call

    assert_includes finished, :a
    assert_includes finished, :b
    assert_equal 2, finished.size
  end

  # 2. Failure in one parallel branch: failure is reported
  def test_failure_in_parallel_branch
    defn = build_test_workflow(
      good: {command: "echo ok"},
      bad: {command: "exit 1"}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true).call
    assert result.failure?
    assert_equal :bad, result.error[:failed_node]
  end

  # 3. Layer-sequential guarantee: step in layer 2 sees outputs from layer 1
  def test_layer_sequential_guarantee
    defn = build_test_workflow(
      producer: {command: "echo layer1_data"},
      consumer: {type: :ruby, depends_on: [:producer],
                 callable: ->(input) { DAG::Success.new(value: "got: #{input[:producer]}") }}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true).call
    assert result.success?
    assert_equal "got: layer1_data", result.outputs[:consumer].value
  end

  # 4. Repeated runs for race detection: 10 runs, all succeed
  def test_repeated_runs_no_races
    defn = build_test_workflow(
      a: {command: "echo a"},
      b: {command: "echo b"},
      c: {command: "echo c"},
      d: {depends_on: [:a, :b]},
      e: {depends_on: [:b, :c]},
      f: {depends_on: [:d, :e]}
    )

    10.times do |i|
      result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true).call
      assert result.success?, "Run #{i + 1} failed: #{result.error}"
    end
  end

  # 5. Parallel execution produces trace entries for all steps
  def test_parallel_execution_traces_all_steps
    defn = build_test_workflow(
      a: {command: "echo a"},
      b: {command: "echo b"},
      c: {depends_on: [:a, :b]}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true).call
    assert result.success?

    trace = result.trace
    assert_equal 3, trace.size
    names = trace.map(&:name).sort
    assert_equal [:a, :b, :c], names

    # a and b are in layer 0, c is in layer 1
    layer0 = trace.select { |e| e.layer == 0 }.map(&:name).sort
    layer1 = trace.select { |e| e.layer == 1 }.map(&:name)
    assert_equal [:a, :b], layer0
    assert_equal [:c], layer1
  end

  # 6. Parallel results match sequential results
  def test_parallel_matches_sequential
    defn = build_test_workflow(
      x: {command: "echo X"},
      y: {command: "echo Y"},
      z: {depends_on: [:x, :y]}
    )

    seq = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false).call
    par = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true).call

    assert seq.success?
    assert par.success?
    assert_equal seq.outputs[:x].value, par.outputs[:x].value
    assert_equal seq.outputs[:y].value, par.outputs[:y].value
    assert_equal seq.outputs[:z].value, par.outputs[:z].value
  end

  # 7. max_parallelism caps the in-flight worker count but still completes all steps
  def test_max_parallelism_caps_window_but_completes_all
    defn = build_test_workflow(
      a: {command: "echo a"},
      b: {command: "echo b"},
      c: {command: "echo c"},
      d: {command: "echo d"},
      e: {command: "echo e"}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: true, max_parallelism: 2).call

    assert result.success?
    assert_equal 5, result.outputs.size
    %i[a b c d e].each do |name|
      assert_equal name.to_s, result.outputs[name].value
    end
  end

  # 8. max_parallelism: 1 still uses the threaded path but is effectively serial
  def test_max_parallelism_one_completes_correctly
    defn = build_test_workflow(
      a: {command: "echo a"},
      b: {command: "echo b"},
      c: {command: "echo c"}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: true, max_parallelism: 1).call

    assert result.success?
    %i[a b c].each { |n| assert_equal n.to_s, result.outputs[n].value }
  end

  # 9. max_parallelism rejects nonsense values at construction time
  def test_max_parallelism_rejects_zero
    defn = build_test_workflow(a: {command: "echo a"})
    assert_raises(ArgumentError) do
      DAG::Workflow::Runner.new(defn.graph, defn.registry, max_parallelism: 0)
    end
  end

  # 10. Default max_parallelism is set
  def test_default_max_parallelism_is_positive
    assert DAG::Workflow::Runner::DEFAULT_MAX_PARALLELISM >= 1
    assert DAG::Workflow::Runner::DEFAULT_MAX_PARALLELISM <= 8
  end

  # =====================================================================
  # Strategy-explicit tests
  # =====================================================================

  # --- Strategy selection by `parallel:` ---

  def test_parallel_true_is_threads
    defn = build_test_workflow(a: {command: "echo a"})
    runner = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: true)
    assert_kind_of DAG::Workflow::Parallel::Threads, runner.instance_variable_get(:@strategy)
  end

  def test_parallel_false_is_sequential
    defn = build_test_workflow(a: {command: "echo a"})
    runner = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: false)
    assert_kind_of DAG::Workflow::Parallel::Sequential, runner.instance_variable_get(:@strategy)
  end

  def test_parallel_symbol_forms
    defn = build_test_workflow(a: {command: "echo a"})
    {
      sequential: DAG::Workflow::Parallel::Sequential,
      threads: DAG::Workflow::Parallel::Threads,
      processes: DAG::Workflow::Parallel::Processes
    }.each do |sym, klass|
      runner = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: sym)
      assert_kind_of klass, runner.instance_variable_get(:@strategy), "expected #{sym} -> #{klass}"
    end
  end

  def test_parallel_unknown_mode_raises
    defn = build_test_workflow(a: {command: "echo a"})
    assert_raises(ArgumentError) do
      DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :nonsense)
    end
  end

  def test_parallel_ractors_mode_is_no_longer_recognized
    defn = build_test_workflow(a: {command: "echo a"})
    error = assert_raises(ArgumentError) do
      DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :ractors)
    end
    assert_match(/Unknown parallel mode/, error.message)
  end

  # --- Sequential strategy ---

  def test_sequential_strategy_runs_all_steps
    defn = build_test_workflow(
      a: {command: "echo a"},
      b: {command: "echo b"},
      c: {command: "echo c"}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :sequential).call

    assert result.success?
    %i[a b c].each { |n| assert_equal n.to_s, result.outputs[n].value }
  end

  # --- Threads strategy ---

  def test_threads_strategy_caps_concurrency_with_sleeping_commands
    # Six 0.3s sleeps, cap=2 → ~0.9s; cap=6 → ~0.3s. We allow generous slack
    # for CI variance but still want to confirm the cap actually slows things.
    defs = (1..6).to_h { |i| [:"n#{i}", {command: "sleep 0.3; echo #{i}"}] }
    defn = build_test_workflow(**defs)

    capped = time_run(defn, parallel: :threads, max_parallelism: 2)
    full = time_run(defn, parallel: :threads, max_parallelism: 6)

    assert capped > full, "expected cap=2 (#{capped.round(2)}s) > cap=6 (#{full.round(2)}s)"
    assert capped < 2.0, "cap=2 should be much less than fully sequential (#{capped.round(2)}s)"
    assert full < 1.0, "cap=6 should be near a single sleep duration (#{full.round(2)}s)"
  end

  def test_threads_strategy_failure_in_branch_reports_correctly
    defn = build_test_workflow(
      good: {command: "echo ok"},
      bad: {command: "exit 1"}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :threads).call
    assert result.failure?
    assert_equal :bad, result.error[:failed_node]
  end

  # Worker boundary: if anything below StandardError reaches the bottom of the
  # worker thread, the parent must not deadlock on queue.pop. The strategy
  # catches Exception and pushes a synthetic Failure so the runner keeps going.
  # Boundary check: a step executor that returns anything other than a
  # DAG::Result must be wrapped in a clean Failure by Strategy.run_task,
  # not propagated and crashed on later when Runner#resolve_input calls
  # `.value` on it. This is the safety net for the most common :ruby
  # footgun (callable returning a plain value instead of a Result).
  def test_strategy_wraps_non_result_executor_return_into_failure
    # A custom executor that violates the contract on purpose.
    klass = Class.new do
      def call(_step, _input) = "raw string, not a Result"
    end
    type = :"_test_bad_return_#{object_id}"
    DAG::Workflow::Steps.register(type, klass, yaml_safe: false)

    graph = DAG::Graph.new.add_node(:bad)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :bad, type: type))

    %i[sequential threads processes].each do |mode|
      next if mode == :processes && !Process.respond_to?(:fork)
      result = DAG::Workflow::Runner.new(graph, registry, parallel: mode).call

      assert result.failure?, "expected failure on #{mode}"
      assert_equal :bad, result.error[:failed_node]
      step_error = result.error[:step_error]
      assert_equal :step_bad_return, step_error[:code], "wrong code on #{mode}"
      assert_equal "String", step_error[:returned_class]
      assert_equal mode, step_error[:strategy]
      assert_match(/instead of a DAG::Result/, step_error[:message])
    end
  end

  # Plain :ruby step with a callable that returns a String instead of a
  # Result is the most common form of the contract violation. Verifies the
  # downstream Runner does not crash later in resolve_input.
  def test_ruby_callable_returning_non_result_does_not_cascade_into_crash
    graph = DAG::Graph.new.add_node(:producer).add_node(:consumer).add_edge(:producer, :consumer)
    registry = DAG::Workflow::Registry.new
    # Forgot to wrap in Success — this used to cause a NoMethodError on
    # String when the consumer's input got resolved.
    registry.register(DAG::Workflow::Step.new(name: :producer, type: :ruby,
      callable: ->(_input) { "I forgot to wrap" }))
    registry.register(DAG::Workflow::Step.new(name: :consumer, type: :ruby,
      callable: ->(input) { DAG::Success.new(value: input) }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: false).call
    assert result.failure?
    assert_equal :producer, result.error[:failed_node]
    assert_equal :step_bad_return, result.error[:step_error][:code]
    refute result.outputs.key?(:consumer), "consumer must not have run"
  end

  def test_threads_strategy_does_not_deadlock_when_worker_raises_below_standard_error
    klass = Class.new do
      def call(_step, _input)
        raise NoMemoryError, "simulated worker death"
      end
    end
    type = :"_test_worker_death_#{object_id}"
    DAG::Workflow::Steps.register(type, klass, yaml_safe: false)

    graph = DAG::Graph.new.add_node(:dies)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :dies, type: type))

    result = Timeout.timeout(5) do
      DAG::Workflow::Runner.new(graph, registry, parallel: :threads).call
    end

    assert result.failure?
    assert_equal :dies, result.error[:failed_node]
    step_error = result.error[:step_error]
    assert_equal :worker_died, step_error[:code]
    assert_match(/worker for dies died/, step_error[:message])
    assert_equal :threads, step_error[:strategy]
  end

  # --- Processes strategy ---

  def test_processes_strategy_runs_all_steps
    defs = (1..4).to_h { |i| [:"n#{i}", {command: "echo #{i}"}] }
    defn = build_test_workflow(**defs)
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :processes).call

    assert result.success?
    (1..4).each { |i| assert_equal i.to_s, result.outputs[:"n#{i}"].value }
  end

  def test_processes_strategy_caps_concurrency
    defs = (1..6).to_h { |i| [:"n#{i}", {command: "sleep 0.3; echo #{i}"}] }
    defn = build_test_workflow(**defs)

    capped = time_run(defn, parallel: :processes, max_parallelism: 2)
    full = time_run(defn, parallel: :processes, max_parallelism: 6)

    assert capped > full, "expected cap=2 (#{capped.round(2)}s) > cap=6 (#{full.round(2)}s)"
    assert full < 1.0, "cap=6 should be near a single sleep duration (#{full.round(2)}s)"
  end

  def test_processes_strategy_failure_in_branch_reports_correctly
    defn = build_test_workflow(
      good: {command: "echo ok"},
      bad: {command: "exit 1"}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :processes).call
    assert result.failure?
    assert_equal :bad, result.error[:failed_node]
  end

  # Pipe-buffer regression: a step whose stdout exceeds the OS pipe buffer
  # (~64 KB on Linux/macOS) used to deadlock the old single-blocking-read
  # implementation. The current strategy drains incrementally with
  # read_nonblock inside an IO.select loop.
  def test_processes_strategy_handles_payload_larger_than_pipe_buffer
    defn = build_test_workflow(
      big: {command: "ruby -e 'print \"x\" * 200_000'", timeout: 10}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :processes).call
    assert result.success?
    assert_equal 200_000, result.outputs[:big].value.length
  end

  def test_processes_strategy_handles_multiple_large_payloads_concurrently
    defs = (1..4).to_h { |i| [:"big#{i}", {command: "ruby -e 'print \"#{i}\" * 80_000'", timeout: 10}] }
    defn = build_test_workflow(**defs)
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: :processes, max_parallelism: 2).call

    assert result.success?
    (1..4).each do |i|
      assert_equal 80_000, result.outputs[:"big#{i}"].value.length
    end
  end

  # EINTR regression: `read_nonblock(exception: false)` only suppresses
  # IO::WaitReadable / EOFError, NOT Errno::EINTR. Under high concurrency
  # the parent receives SIGCHLD constantly and one will eventually land
  # mid-syscall, surfacing EINTR up out of drain_into. The strategy must
  # retry the read instead of crashing the parent. Found by the soak rig
  # at parallelism=32 after ~1 minute of steady-state load; this test
  # captures the contract directly via a fake IO so it stays deterministic.
  def test_processes_strategy_drain_into_retries_on_eintr
    skip unless Process.respond_to?(:fork)

    strategy = DAG::Workflow::Parallel::Processes.new(max_parallelism: 1)
    fake_io = Object.new
    sequence = [:eintr, "first chunk ", :eintr, "second chunk", :eof]
    fake_io.define_singleton_method(:read_nonblock) do |_size, exception:|
      case (step = sequence.shift)
      when :eintr then raise Errno::EINTR
      when :eof then nil
      else step
      end
    end

    buffer = +""
    eof = strategy.send(:drain_into, fake_io, buffer)

    assert_equal true, eof
    assert_equal "first chunk second chunk", buffer
    assert_empty sequence, "drain_into did not consume the full sequence"
  end

  # Exception path: the yield block raises on the FIRST completion while
  # two other children are still running. The ensure clause must reap every
  # in-flight child via the TERM -> KILL ladder within a bounded timeout.
  # A missing ladder would let the test hit the Timeout.timeout(5) boundary.
  #
  # The :ruby callables trap TERM in the forked worker so the grace window
  # in reap_batch must actually elapse (covers `break if deadline`) and the
  # KILL escalation must do the real work.
  def test_processes_strategy_cleans_up_children_on_exception
    strategy = DAG::Workflow::Parallel::Processes.new(max_parallelism: 3)
    fast = DAG::Workflow::Step.new(name: :fast, type: :ruby,
      callable: ->(_) { DAG::Success.new(value: "done") })
    slow_term_resistant = ->(name) {
      DAG::Workflow::Step.new(name: name, type: :ruby, callable: ->(_) {
        Signal.trap("TERM") {}
        sleep 30
        DAG::Success.new(value: "late")
      })
    }
    steps = [fast, slow_term_resistant.call(:slow1), slow_term_resistant.call(:slow2)]
    tasks = steps.map do |step|
      DAG::Workflow::Parallel::Task.new(
        name: step.name, step: step, input: {},
        executor_class: DAG::Workflow::Steps::Ruby, input_keys: []
      )
    end

    boom = Class.new(StandardError)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(boom) do
      Timeout.timeout(5) do
        strategy.execute(tasks) { |*_| raise boom, "yield exploded" }
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t

    # Must complete well under the 30-second sleep the late children were
    # doing; the cleanup ladder should bring them down in ~100ms.
    assert elapsed < 3.0, "expected fast cleanup, took #{elapsed.round(2)}s"
  end

  def test_strategy_base_class_execute_raises_not_implemented
    base = DAG::Workflow::Parallel::Strategy.new(max_parallelism: 1)
    assert_raises(NotImplementedError) { base.execute([]) }
  end

  def test_strategy_run_task_wraps_step_exceptions_into_failure
    # Use a custom executor class whose #call raises directly. The built-in
    # :ruby step rescues its own exceptions, so it never reaches the
    # Strategy.run_task rescue clause.
    raising_executor = Class.new do
      def call(_step, _input)
        raise "executor kaboom"
      end
    end
    step = DAG::Workflow::Step.new(name: :crash, type: :exec, command: "")
    task = DAG::Workflow::Parallel::Task.new(
      name: :crash, step: step, input: {},
      executor_class: raising_executor, input_keys: []
    )
    name, result, _started, _finished, _duration = DAG::Workflow::Parallel::Sequential.run_task(task)
    assert_equal :crash, name
    assert result.failure?
    assert_equal :step_raised, result.error[:code]
    assert_match(/executor kaboom/, result.error[:message])
  end

  def test_processes_decode_payload_handles_corrupt_marshal_data
    strategy = DAG::Workflow::Parallel::Processes.new(max_parallelism: 1)
    fake_task = Struct.new(:name).new(:bad)
    name, result, _started, _finished, _duration =
      strategy.send(:decode_payload, fake_task, "definitely not marshal data")
    assert_equal :bad, name
    assert result.failure?
    assert_equal :decode_failed, result.error[:code]
  end

  def test_processes_waitpid_nohang_returns_true_for_already_reaped_pid
    strategy = DAG::Workflow::Parallel::Processes.new(max_parallelism: 1)
    pid = Process.fork { exit!(0) }
    Process.waitpid(pid) # reap it explicitly so the next call hits ECHILD
    assert_equal true, strategy.send(:waitpid_nohang, pid)
  end

  def test_processes_strategy_handles_empty_child_payload
    # Child exits before writing any payload to the pipe; the parent reads
    # EOF on an empty buffer and synthesizes an :empty_child_payload Failure.
    defn = build_test_workflow(
      crash: {type: :ruby, callable: ->(_) { exit!(0) }}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :processes).call

    assert result.failure?
    step_error = result.error[:step_error]
    assert_equal :empty_child_payload, step_error[:code]
    assert_match(/exited without writing/, step_error[:message])
  end

  private

  def time_run(defn, **opts)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    DAG::Workflow::Runner.new(defn.graph, defn.registry, **opts).call
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end
end
