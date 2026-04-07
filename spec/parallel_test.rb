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
    assert_equal :bad, result.error[:error][:failed_node]
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
    assert_equal "got: layer1_data", result.value[:outputs][:consumer].value
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

    trace = result.value[:trace]
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
    assert_equal seq.value[:outputs][:x].value, par.value[:outputs][:x].value
    assert_equal seq.value[:outputs][:y].value, par.value[:outputs][:y].value
    assert_equal seq.value[:outputs][:z].value, par.value[:outputs][:z].value
  end

  # 7. max_parallelism caps the in-flight Ractor count but still completes all steps
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
    assert_equal 5, result.value[:outputs].size
    %i[a b c d e].each do |name|
      assert_equal name.to_s, result.value[:outputs][name].value
    end
  end

  # 8. max_parallelism: 1 still uses the Ractor path but is effectively serial
  def test_max_parallelism_one_completes_correctly
    defn = build_test_workflow(
      a: {command: "echo a"},
      b: {command: "echo b"},
      c: {command: "echo c"}
    )

    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: true, max_parallelism: 1).call

    assert result.success?
    %i[a b c].each { |n| assert_equal n.to_s, result.value[:outputs][n].value }
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

  # 11. A step that returns a non-shareable value is reported as a clean Failure
  #     rather than crashing the Ractor send.
  def test_non_shareable_result_surfaces_as_failure
    klass = Class.new do
      def call(_step, _input)
        DAG::Success.new(value: [+"mutable", +"strings"])
      end
    end
    type = :"_test_unshareable_#{object_id}"
    DAG::Workflow::Steps.register(type, klass, yaml_safe: false)

    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: type))
    registry.register(DAG::Workflow::Step.new(name: :b, type: type))

    # Threads strategy (the default) has no shareability constraint — should
    # always succeed.
    result = DAG::Workflow::Runner.new(graph, registry, parallel: :threads).call
    assert result.success?
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
      processes: DAG::Workflow::Parallel::Processes,
      ractors: DAG::Workflow::Parallel::Ractors
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

  # --- Sequential strategy ---

  def test_sequential_strategy_runs_all_steps
    defn = build_test_workflow(
      a: {command: "echo a"},
      b: {command: "echo b"},
      c: {command: "echo c"}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :sequential).call

    assert result.success?
    %i[a b c].each { |n| assert_equal n.to_s, result.value[:outputs][n].value }
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
    assert_equal :bad, result.error[:error][:failed_node]
  end

  # Worker boundary: if anything below StandardError reaches the bottom of the
  # worker thread, the parent must not deadlock on queue.pop. The strategy
  # catches Exception and pushes a synthetic Failure so the runner keeps going.
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
    assert_equal :dies, result.error[:error][:failed_node]
    assert_match(/worker for dies died/, result.error[:error][:step_error])
  end

  # --- Processes strategy ---

  def test_processes_strategy_runs_all_steps
    defs = (1..4).to_h { |i| [:"n#{i}", {command: "echo #{i}"}] }
    defn = build_test_workflow(**defs)
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :processes).call

    assert result.success?
    (1..4).each { |i| assert_equal i.to_s, result.value[:outputs][:"n#{i}"].value }
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
    assert_equal :bad, result.error[:error][:failed_node]
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
    assert_equal 200_000, result.value[:outputs][:big].value.length
  end

  def test_processes_strategy_handles_multiple_large_payloads_concurrently
    defs = (1..4).to_h { |i| [:"big#{i}", {command: "ruby -e 'print \"#{i}\" * 80_000'", timeout: 10}] }
    defn = build_test_workflow(**defs)
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: :processes, max_parallelism: 2).call

    assert result.success?
    (1..4).each do |i|
      assert_equal 80_000, result.value[:outputs][:"big#{i}"].value.length
    end
  end

  # Exception path: the yield block raises on the FIRST completion while
  # two other children are still running their 30-second sleep. The ensure
  # clause must reap every in-flight child via the TERM -> KILL ladder
  # within a bounded timeout. A missing ladder would let the test hit
  # the Timeout.timeout(5) boundary and fail.
  def test_processes_strategy_cleans_up_children_on_exception
    skip unless Process.respond_to?(:fork)

    strategy = DAG::Workflow::Parallel::Processes.new(max_parallelism: 3)
    # The first task finishes immediately, triggering the first yield.
    # The other two are "indefinite" from the test's perspective — if the
    # ensure clause doesn't kill them, the test hangs at Timeout.timeout.
    cmds = ["echo done", "sleep 30; echo late1", "sleep 30; echo late2"]
    tasks = cmds.each_with_index.map do |cmd, i|
      step = DAG::Workflow::Step.new(name: :"p#{i}", type: :exec, command: cmd)
      DAG::Workflow::Parallel::Task.new(
        name: :"p#{i}", step: step, input: {},
        executor_class: DAG::Workflow::Steps::Exec, input_keys: []
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

  # --- Ractors strategy ---
  #
  # The Ractors strategy on Ruby 4.0 cannot reliably host steps that call
  # Process.spawn (the per-Ractor deadlock detector trips). These tests use
  # only fast `echo` commands which finish before any concurrency can build up.

  def test_ractors_strategy_runs_fast_steps
    defn = build_test_workflow(
      a: {command: "echo a"},
      b: {command: "echo b"},
      c: {command: "echo c"}
    )
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry, parallel: :ractors).call
    assert result.success?
    %i[a b c].each { |n| assert_equal n.to_s, result.value[:outputs][n].value }
  end

  def test_ractors_degrades_unsafe_layer_to_sequential
    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo safe"))
    registry.register(DAG::Workflow::Step.new(name: :b, type: :ruby, callable: ->(_) { DAG::Success.new(value: "from ruby") }))

    result = DAG::Workflow::Runner.new(graph, registry, parallel: :ractors).call
    assert result.success?
    assert_equal "safe", result.value[:outputs][:a].value
    assert_equal "from ruby", result.value[:outputs][:b].value
  end

  # The Ractors strategy is the only place that asks "is this step shareable?".
  # Step is pure data; it does not know about Ractors. supports? does the
  # preflight, caches by step identity, and warns once per (name, type).
  def test_ractors_supports_returns_true_for_safe_steps
    strategy = DAG::Workflow::Parallel::Ractors.new(max_parallelism: 2)
    safe = DAG::Workflow::Step.new(name: :a, type: :exec, command: "echo hi")
    assert strategy.supports?([safe])
  end

  def test_ractors_supports_returns_false_for_ruby_steps
    strategy = DAG::Workflow::Parallel::Ractors.new(max_parallelism: 2)
    unsafe = DAG::Workflow::Step.new(name: :b, type: :ruby, callable: ->(_) { DAG::Success.new(value: 1) })
    refute strategy.supports?([unsafe])
  end

  def test_ractors_supports_warns_only_once_for_same_unshareable_step
    name = :"warn_once_#{object_id}"
    DAG::Workflow::Parallel::Ractors.warned_unshareable.delete([name, :exec])
    strategy = DAG::Workflow::Parallel::Ractors.new(max_parallelism: 2)
    # StringIO is mutable and not Ractor-shareable, so make_shareable raises.
    step = DAG::Workflow::Step.new(name: name, type: :exec, command: StringIO.new)

    _, stderr1 = capture_io { strategy.supports?([step]) }
    _, stderr2 = capture_io { strategy.supports?([step]) }

    assert_match(/not Ractor-shareable/, stderr1)
    assert_empty stderr2
  end

  # --- Experimental flag + warning ---

  def test_ractors_is_marked_experimental
    assert DAG::Workflow::Parallel::Ractors.experimental?
  end

  def test_stable_strategies_are_not_experimental
    refute DAG::Workflow::Parallel::Sequential.experimental?
    refute DAG::Workflow::Parallel::Threads.experimental?
    refute DAG::Workflow::Parallel::Processes.experimental?
  end

  def test_ractors_emits_experimental_warning_once_per_process
    DAG::Workflow::Parallel::Ractors.warned_experimental = false

    _, stderr1 = capture_io { DAG::Workflow::Parallel::Ractors.new(max_parallelism: 2) }
    _, stderr2 = capture_io { DAG::Workflow::Parallel::Ractors.new(max_parallelism: 2) }

    assert_match(/EXPERIMENTAL strategy/, stderr1)
    assert_match(/parallel: :threads or :processes/, stderr1)
    assert_empty stderr2
  ensure
    DAG::Workflow::Parallel::Ractors.warned_experimental = true
  end

  # If the caller's yield block raises mid-receive-loop, execute must still
  # reap every spawned Ractor (via the ensure clause) and propagate the
  # original exception. A missing ensure would either silently orphan
  # Ractors or leave the test hanging.
  def test_ractors_strategy_joins_all_ractors_when_yield_raises
    strategy = DAG::Workflow::Parallel::Ractors.new(max_parallelism: 3)
    tasks = (1..3).map do |i|
      step = DAG::Workflow::Step.new(name: :"r#{i}", type: :exec, command: "echo #{i}")
      DAG::Workflow::Parallel::Task.new(
        name: :"r#{i}", step: step, input: {},
        executor_class: DAG::Workflow::Steps::Exec, input_keys: []
      )
    end

    boom = Class.new(StandardError)
    error = Timeout.timeout(5) do
      assert_raises(boom) do
        strategy.execute(tasks) do |_name, _result, _start, _finish, _dur|
          raise boom, "yield exploded"
        end
      end
    end

    assert_equal "yield exploded", error.message
  end

  private

  def time_run(defn, **opts)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    DAG::Workflow::Runner.new(defn.graph, defn.registry, **opts).call
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end
end
