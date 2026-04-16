# frozen_string_literal: true

require_relative "test_helper"

class ExecutionPersistenceTest < Minitest::Test
  include TestHelpers

  def test_node_path_for_applies_prefix
    persistence = build_persistence(node_path_prefix: [:parent])

    assert_equal [:parent, :child], persistence.node_path_for(:child)
  end

  def test_load_reusable_result_returns_latest_result
    store = build_memory_store
    store.begin_run(workflow_id: "wf-persist", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-persist",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: "payload"),
      reusable: true,
      superseded: false
    )

    persistence = build_persistence(execution_store: store)

    assert_equal "payload", persistence.load_reusable_result(:fetch).value
  end

  def test_persist_step_result_saves_trace_and_success_output
    store = build_memory_store
    store.begin_run(workflow_id: "wf-persist", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    persistence = build_persistence(execution_store: store)
    task = build_task(node_path: [:fetch], attempt: 2)
    result = DAG::Success.new(value: "done")
    entries = [build_trace_entry(name: :fetch)]

    persistence.persist_step_result(task, result, entries)

    run = store.load_run("wf-persist")
    node = store.load_node(workflow_id: "wf-persist", node_path: [:fetch])
    output = store.load_output(workflow_id: "wf-persist", node_path: [:fetch])

    assert_equal 1, run[:trace].size
    assert_equal :completed, node[:state]
    assert_equal 1, output[:version]
    assert_equal "done", output[:result].value
  end

  def test_persist_step_result_assigns_next_monotonic_output_version
    store = build_memory_store
    store.begin_run(workflow_id: "wf-persist", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-persist",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: "old"),
      reusable: false,
      superseded: false
    )
    persistence = build_persistence(execution_store: store)
    task = build_task(node_path: [:fetch], attempt: 3)

    persistence.persist_step_result(task, DAG::Success.new(value: "new"), [build_trace_entry(name: :fetch)])

    output = store.load_output(workflow_id: "wf-persist", node_path: [:fetch])
    assert_equal 2, output[:version]
    assert_equal "new", output[:result].value
  end

  def test_persist_step_result_saves_failure_without_output
    store = build_memory_store
    store.begin_run(workflow_id: "wf-persist", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    persistence = build_persistence(execution_store: store)
    task = build_task(node_path: [:fetch], attempt: 1)
    result = DAG::Failure.new(error: {code: :boom, message: "failed"})
    entries = [build_trace_entry(name: :fetch, status: :failure)]

    persistence.persist_step_result(task, result, entries)

    node = store.load_node(workflow_id: "wf-persist", node_path: [:fetch])

    assert_equal :failed, node[:state]
    assert_equal :boom, node[:reason][:code]
    assert_nil store.load_output(workflow_id: "wf-persist", node_path: [:fetch])
  end

  def test_persist_step_result_skips_lifecycle_only_results
    store = build_memory_store
    store.begin_run(workflow_id: "wf-persist", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    persistence = build_persistence(execution_store: store)
    task = build_task(node_path: [:fetch], attempt: 1)
    result = DAG::Success.new(value: nil)
    entries = [build_trace_entry(name: :fetch)]

    persistence.persist_step_result(task, result, entries, skip_result: true)

    run = store.load_run("wf-persist")

    assert_equal [], run[:trace]
    assert_nil store.load_node(workflow_id: "wf-persist", node_path: [:fetch])
  end

  def test_pause_requested_reads_store_flag
    store = build_memory_store
    store.begin_run(workflow_id: "wf-persist", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.set_pause_flag(workflow_id: "wf-persist", paused: true)

    persistence = build_persistence(execution_store: store)

    assert persistence.pause_requested?
  end

  private

  def build_persistence(execution_store: nil, node_path_prefix: [])
    registry = DAG::Workflow::Registry.new
    registry.register(DAG::Workflow::Step.new(
      name: :fetch,
      type: :ruby,
      resume_key: "fetch-v1",
      callable: ->(_input) { DAG::Success.new(value: "ok") }
    ))

    DAG::Workflow::ExecutionPersistence.new(
      execution_store: execution_store,
      workflow_id: execution_store ? "wf-persist" : nil,
      registry: registry,
      clock: build_clock,
      node_path_prefix: node_path_prefix
    )
  end

  def build_task(node_path:, attempt:)
    execution = DAG::Workflow::StepExecution.new(
      workflow_id: "wf-persist",
      node_path: node_path,
      attempt: attempt,
      deadline: nil,
      depth: 0,
      parallel: :sequential,
      execution_store: build_memory_store,
      event_bus: nil
    )

    Data.define(:execution).new(execution: execution)
  end

  def build_trace_entry(name:, status: :success)
    DAG::Workflow::TraceEntry.new(
      name: name,
      layer: 0,
      started_at: 1.0,
      finished_at: 2.0,
      duration_ms: 1000.0,
      status: status,
      input_keys: [],
      attempt: 1,
      retried: false
    )
  end
end
