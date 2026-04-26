# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ExecutionStoreTest < Minitest::Test
  include TestHelpers

  def test_load_output_returns_isolated_result_snapshot
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    original_value = {payload: ["a"]}
    store.begin_run(workflow_id: "wf-store", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-store",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: original_value),
      reusable: true,
      superseded: false
    )
    original_value[:payload] << "outside"

    loaded = store.load_output(workflow_id: "wf-store", node_path: [:fetch])
    assert_raises(FrozenError) { loaded[:result].value[:payload] << "b" }

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

  def test_mark_obsolete_supersedes_reusable_outputs_and_records_obsolete_cause
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(workflow_id: "wf-obsolete", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
    store.save_output(
      workflow_id: "wf-obsolete",
      node_path: [:fetch],
      version: 1,
      result: DAG::Success.new(value: "v1"),
      reusable: true,
      superseded: false
    )

    store.mark_obsolete(
      workflow_id: "wf-obsolete",
      node_paths: [[:fetch]],
      cause: {code: :subtree_replaced, replaced_from: [:fetch]}
    )

    node = store.load_node(workflow_id: "wf-obsolete", node_path: [:fetch])
    assert_equal :obsolete, node[:state]
    assert_equal({code: :subtree_replaced, replaced_from: [:fetch]}, node[:obsolete_cause])
    assert_nil store.load_output(workflow_id: "wf-obsolete", node_path: [:fetch])

    history = store.load_output(workflow_id: "wf-obsolete", node_path: [:fetch], version: :all)
    assert_equal [1], history.map { |entry| entry[:version] }
    assert_equal [true], history.map { |entry| entry[:superseded] }
  end

  def test_update_definition_replaces_fingerprint_and_unions_node_paths
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(
      workflow_id: "wf-definition-update",
      definition_fingerprint: "fp-1",
      node_paths: [[:source], [:process], [:report]]
    )

    store.update_definition(
      workflow_id: "wf-definition-update",
      definition_fingerprint: "fp-2",
      node_paths: [[:source], [:normalize], [:summarize], [:report]]
    )

    run = store.load_run("wf-definition-update")

    assert_equal "fp-2", run[:definition_fingerprint]
    assert_equal [[:normalize], [:process], [:report], [:source], [:summarize]], run[:node_paths].sort_by { |path| path.map(&:to_s) }
  end

  def test_file_store_update_definition_persists_fingerprint_and_node_paths_across_instances
    Dir.mktmpdir("dag-file-store-definition-update") do |dir|
      store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
      store.begin_run(
        workflow_id: "wf-file-definition-update",
        definition_fingerprint: "fp-1",
        node_paths: [[:source], [:process], [:report]]
      )

      store.update_definition(
        workflow_id: "wf-file-definition-update",
        definition_fingerprint: "fp-2",
        node_paths: [[:source], [:normalize], [:summarize], [:report]]
      )

      reopened = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
      run = reopened.load_run("wf-file-definition-update")

      assert_equal "fp-2", run[:definition_fingerprint]
      assert_equal [[:normalize], [:process], [:report], [:source], [:summarize]], run[:node_paths].sort_by { |path| path.map(&:to_s) }
    end
  end

  def test_file_store_persists_runs_outputs_and_trace_across_instances
    Dir.mktmpdir("dag-file-store") do |dir|
      store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
      entry = DAG::Workflow::TraceEntry.new(
        name: :fetch,
        layer: 0,
        started_at: 1.0,
        finished_at: 2.0,
        duration_ms: 1000.0,
        status: :success,
        input_keys: [:source],
        attempt: 1,
        retried: false
      )

      store.begin_run(workflow_id: "wf-file", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
      store.set_node_state(workflow_id: "wf-file", node_path: [:fetch], state: :completed)
      store.append_trace(workflow_id: "wf-file", entry: entry)
      store.save_output(
        workflow_id: "wf-file",
        node_path: [:fetch],
        version: 1,
        result: DAG::Success.new(value: {payload: ["a"]}),
        reusable: true,
        superseded: false,
        saved_at: Time.utc(2026, 4, 17, 8, 0, 0)
      )
      store.set_workflow_status(workflow_id: "wf-file", status: :completed)

      reopened = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
      run = reopened.load_run("wf-file")
      output = reopened.load_output(workflow_id: "wf-file", node_path: [:fetch])

      assert_equal :completed, run[:workflow_status]
      assert_equal [:fetch], run[:trace].map(&:name)
      assert_equal({payload: ["a"]}, output[:result].value)

      output[:result].value[:payload] << "b"
      assert_equal({payload: ["a"]}, reopened.load_output(workflow_id: "wf-file", node_path: [:fetch])[:result].value)
    end
  end

  def test_file_store_concurrent_append_trace_does_not_drop_entries
    Dir.mktmpdir("dag-file-store-concurrent-trace") do |dir|
      store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
      store.begin_run(workflow_id: "wf-file-concurrent", definition_fingerprint: "fp-1", node_paths: [[:fetch]])

      threads = 8.times.map do |thread_index|
        Thread.new do
          50.times do |entry_index|
            store.append_trace(
              workflow_id: "wf-file-concurrent",
              entry: build_trace_entry(:"fetch_#{thread_index}_#{entry_index}")
            )
          end
        end
      end
      threads.each(&:join)

      run = store.load_run("wf-file-concurrent")
      reopened = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)

      assert_equal 400, run[:trace].size
      assert_equal 400, run[:trace].map(&:name).uniq.size
      assert_equal 400, reopened.load_run("wf-file-concurrent")[:trace].size
    end
  end

  def test_file_store_clear_run_clears_cached_run
    Dir.mktmpdir("dag-file-store-clear-cache") do |dir|
      store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
      store.begin_run(workflow_id: "wf-file-clear", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
      store.load_run("wf-file-clear")

      store.clear_run(workflow_id: "wf-file-clear")

      assert_nil store.load_run("wf-file-clear")
      assert_nil DAG::Workflow::ExecutionStore::FileStore.new(dir: dir).load_run("wf-file-clear")
    end
  end

  def test_file_store_cached_trace_entries_are_isolated_from_caller_mutation
    Dir.mktmpdir("dag-file-store-trace-isolation") do |dir|
      store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
      store.begin_run(workflow_id: "wf-file-trace-isolation", definition_fingerprint: "fp-1", node_paths: [[:fetch]])
      entry = build_trace_entry(:fetch, input_keys: [:source])

      store.append_trace(workflow_id: "wf-file-trace-isolation", entry: entry)
      entry.input_keys << :mutated

      run = store.load_run("wf-file-trace-isolation")

      assert_equal [:source], run[:trace].first.input_keys
    end
  end

  private

  def build_trace_entry(name, input_keys: [])
    DAG::Workflow::TraceEntry.new(
      name: name,
      layer: 0,
      started_at: 1.0,
      finished_at: 2.0,
      duration_ms: 1000.0,
      status: :success,
      input_keys: input_keys,
      attempt: 1,
      retried: false
    )
  end
end
