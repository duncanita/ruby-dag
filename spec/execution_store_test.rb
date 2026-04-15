# frozen_string_literal: true

require_relative "test_helper"

class ExecutionStoreTest < Minitest::Test
  def test_load_output_returns_isolated_result_snapshot
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(workflow_id: "wf-store", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-store",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: {payload: ["a"]}),
      reusable: true,
      superseded: false
    )

    loaded = store.load_output(workflow_id: "wf-store", node_path: [:fetch])
    loaded[:result].value[:payload] << "b"

    reloaded = store.load_output(workflow_id: "wf-store", node_path: [:fetch])
    assert_equal ["a"], reloaded[:result].value[:payload]
  end

  def test_load_run_returns_isolated_trace_entries
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(workflow_id: "wf-trace", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.append_trace(
      workflow_id: "wf-trace",
      entry: DAG::Workflow::TraceEntry.new(
        name: :fetch,
        layer: 0,
        started_at: 1.0,
        finished_at: 2.0,
        duration_ms: 1000.0,
        status: :success,
        input_keys: [:a],
        attempt: 1,
        retried: false
      )
    )

    loaded = store.load_run("wf-trace")
    loaded[:trace].first.input_keys << :b

    reloaded = store.load_run("wf-trace")
    assert_equal [:a], reloaded[:trace].first.input_keys
  end

  def test_load_output_returns_isolated_saved_at_snapshot
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    saved_at = Time.utc(2026, 4, 15, 9, 0, 0)
    store.begin_run(workflow_id: "wf-saved-at", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-saved-at",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: "ok"),
      reusable: true,
      superseded: false,
      saved_at: saved_at
    )

    loaded = store.load_output(workflow_id: "wf-saved-at", node_path: [:fetch])
    loaded[:saved_at] = saved_at + 3600

    reloaded = store.load_output(workflow_id: "wf-saved-at", node_path: [:fetch])
    assert_equal saved_at, reloaded[:saved_at]
  end
end
