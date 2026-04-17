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

  def test_apply_subtree_replacement_impact_marks_obsolete_root_and_stale_completed_descendants
    store = build_memory_store
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :source) }},
      process: {type: :ruby, depends_on: [:source], callable: ->(_) { DAG::Success.new(value: :process) }},
      report: {type: :ruby, depends_on: [:process], callable: ->(_) { DAG::Success.new(value: :report) }},
      notify: {type: :ruby, depends_on: [:report], callable: ->(_) { DAG::Success.new(value: :notify) }}
    )

    store.begin_run(
      workflow_id: "wf-apply-impact",
      definition_fingerprint: "fp-1",
      node_paths: [[:source], [:process], [:report], [:notify]]
    )
    save_completed_output(store, workflow_id: "wf-apply-impact", node_path: [:process], version: 1, value: :process_v1)
    save_completed_output(store, workflow_id: "wf-apply-impact", node_path: [:report], version: 1, value: :report_v1)
    store.set_node_state(workflow_id: "wf-apply-impact", node_path: [:notify], state: :waiting)

    impact = DAG::Workflow.apply_subtree_replacement_impact(
      workflow_id: "wf-apply-impact",
      definition: definition,
      root_node: :process,
      execution_store: store,
      cause: {source: :planner}
    )

    assert_equal [[:process]], impact[:obsolete_nodes]
    assert_equal [[:report]], impact[:stale_nodes]

    process = store.load_node(workflow_id: "wf-apply-impact", node_path: [:process])
    report = store.load_node(workflow_id: "wf-apply-impact", node_path: [:report])
    notify = store.load_node(workflow_id: "wf-apply-impact", node_path: [:notify])

    assert_equal :obsolete, process[:state]
    assert_equal :subtree_replaced, process[:obsolete_cause][:code]
    assert_equal :planner, process[:obsolete_cause][:source]
    assert_equal [:process], process[:obsolete_cause][:replaced_from]

    assert_equal :stale, report[:state]
    assert_equal :subtree_replaced, report[:stale_cause][:code]
    assert_equal :planner, report[:stale_cause][:source]
    assert_equal [:process], report[:stale_cause][:replaced_from]

    assert_equal :waiting, notify[:state]
    assert_nil store.load_output(workflow_id: "wf-apply-impact", node_path: [:process])
    assert_nil store.load_output(workflow_id: "wf-apply-impact", node_path: [:report])
    assert_equal [true], store.load_output(workflow_id: "wf-apply-impact", node_path: [:process], version: :all).map { |entry| entry[:superseded] }
    assert_equal [true], store.load_output(workflow_id: "wf-apply-impact", node_path: [:report], version: :all).map { |entry| entry[:superseded] }
  end

  def test_apply_subtree_replacement_impact_rejects_replaced_from_override
    definition = build_test_workflow(
      process: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :process) }}
    )
    store = build_memory_store
    store.begin_run(
      workflow_id: "wf-invalid-impact-cause",
      definition_fingerprint: "fp-1",
      node_paths: [[:process]]
    )
    store.set_node_state(workflow_id: "wf-invalid-impact-cause", node_path: [:process], state: :completed)

    error = assert_raises(ArgumentError) do
      DAG::Workflow.apply_subtree_replacement_impact(
        workflow_id: "wf-invalid-impact-cause",
        definition: definition,
        root_node: :process,
        execution_store: store,
        cause: {replaced_from: [:other]}
      )
    end

    assert_match(/replaced_from/, error.message)
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

  private

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
end
