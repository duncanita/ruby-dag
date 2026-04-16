# frozen_string_literal: true

require_relative "test_helper"

class InvalidationTest < Minitest::Test
  def test_stale_nodes_returns_completed_nodes_marked_stale
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(
      workflow_id: "wf-invalidation",
      definition_fingerprint: "fp-1",
      node_paths: [[:fetch], [:transform], [:report]]
    )

    store.set_node_state(workflow_id: "wf-invalidation", node_path: [:fetch], state: :completed)
    store.set_node_state(workflow_id: "wf-invalidation", node_path: [:transform], state: :stale)
    store.set_node_state(workflow_id: "wf-invalidation", node_path: [:report], state: :waiting)

    assert_equal [[:transform]], DAG::Workflow.stale_nodes(
      workflow_id: "wf-invalidation",
      execution_store: store
    )
  end

  def test_stale_nodes_returns_empty_array_when_run_has_no_stale_nodes
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    store.begin_run(
      workflow_id: "wf-clean",
      definition_fingerprint: "fp-1",
      node_paths: [[:fetch]]
    )
    store.set_node_state(workflow_id: "wf-clean", node_path: [:fetch], state: :completed)

    assert_equal [], DAG::Workflow.stale_nodes(workflow_id: "wf-clean", execution_store: store)
  end

  def test_invalidate_marks_completed_root_and_descendants_stale_and_supersedes_outputs
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    definition = workflow_definition(
      fetch: {type: :ruby, callable: ->(*) { DAG::Success.new(value: "fetch") }},
      transform: {type: :ruby, depends_on: [:fetch], callable: ->(*) { DAG::Success.new(value: "transform") }},
      publish: {type: :ruby, depends_on: [:transform], callable: ->(*) { DAG::Success.new(value: "publish") }},
      notify: {type: :ruby, depends_on: [:fetch], callable: ->(*) { DAG::Success.new(value: "notify") }}
    )

    store.begin_run(
      workflow_id: "wf-cascade",
      definition_fingerprint: "fp-1",
      node_paths: [[:fetch], [:transform], [:publish], [:notify]]
    )
    save_completed_output(store, workflow_id: "wf-cascade", node_path: [:fetch], version: 1, value: "fetch-v1")
    save_completed_output(store, workflow_id: "wf-cascade", node_path: [:transform], version: 1, value: "transform-v1")
    save_completed_output(store, workflow_id: "wf-cascade", node_path: [:publish], version: 1, value: "publish-v1")
    store.set_node_state(workflow_id: "wf-cascade", node_path: [:notify], state: :waiting)

    invalidated = DAG::Workflow.invalidate(
      workflow_id: "wf-cascade",
      node: [:fetch],
      definition: definition,
      execution_store: store
    )

    assert_equal [[:fetch], [:publish], [:transform]], invalidated.sort_by { |path| path.map(&:to_s) }

    assert_stale_node(store, workflow_id: "wf-cascade", node_path: [:fetch], code: :manual_invalidation)
    assert_stale_node(store, workflow_id: "wf-cascade", node_path: [:transform], code: :manual_invalidation)
    assert_stale_node(store, workflow_id: "wf-cascade", node_path: [:publish], code: :manual_invalidation)

    notify = store.load_node(workflow_id: "wf-cascade", node_path: [:notify])
    assert_equal :waiting, notify[:state]

    assert_nil store.load_output(workflow_id: "wf-cascade", node_path: [:fetch])
    assert_nil store.load_output(workflow_id: "wf-cascade", node_path: [:transform])
    assert_nil store.load_output(workflow_id: "wf-cascade", node_path: [:publish])

    history = store.load_output(workflow_id: "wf-cascade", node_path: [:fetch], version: :all)
    assert_equal [true], history.map { |entry| entry[:superseded] }
    assert_equal ["fetch-v1"], history.map { |entry| entry[:result].value }
  end

  def test_invalidate_respects_max_cascade_depth
    store = DAG::Workflow::ExecutionStore::MemoryStore.new
    definition = workflow_definition(
      a: {type: :ruby, callable: ->(*) { DAG::Success.new(value: "a") }},
      b: {type: :ruby, depends_on: [:a], callable: ->(*) { DAG::Success.new(value: "b") }},
      c: {type: :ruby, depends_on: [:b], callable: ->(*) { DAG::Success.new(value: "c") }}
    )

    store.begin_run(
      workflow_id: "wf-depth",
      definition_fingerprint: "fp-1",
      node_paths: [[:a], [:b], [:c]]
    )
    save_completed_output(store, workflow_id: "wf-depth", node_path: [:a], version: 1, value: "a-v1")
    save_completed_output(store, workflow_id: "wf-depth", node_path: [:b], version: 1, value: "b-v1")
    save_completed_output(store, workflow_id: "wf-depth", node_path: [:c], version: 1, value: "c-v1")

    invalidated = DAG::Workflow.invalidate(
      workflow_id: "wf-depth",
      node: [:a],
      definition: definition,
      execution_store: store,
      max_cascade_depth: 1
    )

    assert_equal [[:a], [:b]], invalidated.sort_by { |path| path.map(&:to_s) }
    assert_stale_node(store, workflow_id: "wf-depth", node_path: [:a], code: :manual_invalidation)
    assert_stale_node(store, workflow_id: "wf-depth", node_path: [:b], code: :manual_invalidation)

    node_c = store.load_node(workflow_id: "wf-depth", node_path: [:c])
    assert_equal :completed, node_c[:state]
    refute store.load_output(workflow_id: "wf-depth", node_path: [:c])[:superseded]
  end

  private

  def workflow_definition(steps)
    DAG::Workflow::Loader.from_hash(**steps)
  end

  def save_completed_output(store, workflow_id:, node_path:, version:, value:)
    store.set_node_state(workflow_id: workflow_id, node_path: node_path, state: :completed)
    store.save_output(
      workflow_id: workflow_id,
      node_path: node_path,
      version: version,
      result: DAG::Success.new(value: value),
      reusable: true,
      superseded: false
    )
  end

  def assert_stale_node(store, workflow_id:, node_path:, code:)
    node = store.load_node(workflow_id: workflow_id, node_path: node_path)
    assert_equal :stale, node[:state]
    assert_equal code, node[:stale_cause][:code]
  end
end
