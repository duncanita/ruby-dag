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

  def test_load_output_can_fetch_explicit_version
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(workflow_id: "wf-versions", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-versions",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: "v1"),
      reusable: false,
      superseded: false
    )
    store.save_output(
      workflow_id: "wf-versions",
      node_path: [:fetch],
      version: 2,
      result: DAG::Success.new(value: "v2"),
      reusable: true,
      superseded: false
    )

    loaded = store.load_output(workflow_id: "wf-versions", node_path: [:fetch], version: 1)

    assert_equal 1, loaded[:version]
    assert_equal "v1", loaded[:result].value
  end

  def test_load_output_can_fetch_all_versions_in_ascending_order
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(workflow_id: "wf-all-versions", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-all-versions",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: "v1"),
      reusable: false,
      superseded: false
    )
    store.save_output(
      workflow_id: "wf-all-versions",
      node_path: [:fetch],
      version: 2,
      result: DAG::Success.new(value: "v2"),
      reusable: true,
      superseded: false
    )

    loaded = store.load_output(workflow_id: "wf-all-versions", node_path: [:fetch], version: :all)
    loaded.first[:version] = 99

    reloaded = store.load_output(workflow_id: "wf-all-versions", node_path: [:fetch], version: :all)

    assert_equal [1, 2], reloaded.map { |entry| entry[:version] }
    assert_equal %w[v1 v2], reloaded.map { |entry| entry[:result].value }
  end

  def test_mark_stale_supersedes_reusable_outputs_but_keeps_audit_history
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(workflow_id: "wf-stale", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-stale",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: "v1"),
      reusable: true,
      superseded: false
    )

    store.mark_stale(
      workflow_id: "wf-stale",
      node_paths: [[:fetch]],
      cause: {code: :manual_invalidation}
    )

    assert_nil store.load_output(workflow_id: "wf-stale", node_path: [:fetch])

    history = store.load_output(workflow_id: "wf-stale", node_path: [:fetch], version: :all)
    assert_equal [1], history.map { |entry| entry[:version] }
    assert_equal [true], history.map { |entry| entry[:superseded] }
  end
end
