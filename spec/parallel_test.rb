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
    assert_equal 5, result.value[:outputs].size
    %i[a b c d e].each do |name|
      assert_equal name.to_s, result.value[:outputs][name].value
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

  private

  def time_run(defn, **opts)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    DAG::Workflow::Runner.new(defn.graph, defn.registry, **opts).call
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end
end
