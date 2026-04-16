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
end
