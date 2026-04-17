# frozen_string_literal: true

require_relative "test_helper"

class MutationImpactTest < Minitest::Test
  include TestHelpers

  def test_subtree_replacement_impact_returns_obsolete_root_and_completed_stale_descendants
    store = build_memory_store
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :source) }},
      process: {type: :ruby, depends_on: [:source], callable: ->(_) { DAG::Success.new(value: :process) }},
      report: {type: :ruby, depends_on: [:process], callable: ->(_) { DAG::Success.new(value: :report) }},
      notify: {type: :ruby, depends_on: [:report], callable: ->(_) { DAG::Success.new(value: :notify) }}
    )

    store.begin_run(
      workflow_id: "wf-mutation-impact",
      definition_fingerprint: "fp-1",
      node_paths: [[:source], [:process], [:report], [:notify]]
    )
    store.set_node_state(workflow_id: "wf-mutation-impact", node_path: [:process], state: :completed)
    store.set_node_state(workflow_id: "wf-mutation-impact", node_path: [:report], state: :completed)
    store.set_node_state(workflow_id: "wf-mutation-impact", node_path: [:notify], state: :waiting)

    impact = DAG::Workflow.subtree_replacement_impact(
      workflow_id: "wf-mutation-impact",
      definition: definition,
      root_node: :process,
      execution_store: store
    )

    assert_equal [[:process]], impact[:obsolete_nodes]
    assert_equal [[:report]], impact[:stale_nodes]
  end

  def test_subtree_replacement_impact_returns_empty_arrays_when_run_missing
    definition = build_test_workflow(
      process: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :process) }}
    )

    impact = DAG::Workflow.subtree_replacement_impact(
      workflow_id: "wf-missing",
      definition: definition,
      root_node: :process,
      execution_store: build_memory_store
    )

    assert_equal [], impact[:obsolete_nodes]
    assert_equal [], impact[:stale_nodes]
  end
end
