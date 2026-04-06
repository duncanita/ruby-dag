# frozen_string_literal: true

require_relative "test_helper"

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
end
