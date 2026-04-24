# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

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

  def test_subtree_replacement_impact_rejects_running_root
    definition = build_test_workflow(
      process: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :process) }},
      report: {type: :ruby, depends_on: [:process], callable: ->(_) { DAG::Success.new(value: :report) }}
    )
    store = build_memory_store
    store.begin_run(
      workflow_id: "wf-running-root",
      definition_fingerprint: "fp-1",
      node_paths: [[:process], [:report]]
    )
    store.set_node_state(workflow_id: "wf-running-root", node_path: [:process], state: :running)

    error = assert_raises(ArgumentError) do
      DAG::Workflow.subtree_replacement_impact(
        workflow_id: "wf-running-root",
        definition: definition,
        root_node: :process,
        execution_store: store
      )
    end

    assert_match(/currently be :running/, error.message)
  end

  def test_apply_subtree_replacement_impact_rejects_running_root
    definition = build_test_workflow(
      process: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :process) }},
      report: {type: :ruby, depends_on: [:process], callable: ->(_) { DAG::Success.new(value: :report) }}
    )
    store = build_memory_store
    store.begin_run(
      workflow_id: "wf-running-root-apply",
      definition_fingerprint: "fp-1",
      node_paths: [[:process], [:report]]
    )
    store.set_node_state(workflow_id: "wf-running-root-apply", node_path: [:process], state: :running)

    error = assert_raises(ArgumentError) do
      DAG::Workflow.apply_subtree_replacement_impact(
        workflow_id: "wf-running-root-apply",
        definition: definition,
        root_node: :process,
        execution_store: store
      )
    end

    assert_match(/currently be :running/, error.message)
  end

  def test_subtree_replacement_impact_preserves_upstream_outputs_when_mutated_workflow_reruns
    source_calls = 0
    process_calls = 0
    normalize_calls = 0
    summarize_calls = 0
    report_calls = 0
    store = build_memory_store

    original = build_test_workflow(
      source: {
        type: :ruby,
        resume_key: "source-v1",
        callable: ->(_input) do
          source_calls += 1
          DAG::Success.new(value: "payload")
        end
      },
      process: {
        type: :ruby,
        depends_on: [:source],
        resume_key: "process-v1",
        callable: ->(input) do
          process_calls += 1
          DAG::Success.new(value: input[:source].upcase)
        end
      },
      report: {
        type: :ruby,
        depends_on: [:process],
        resume_key: "report-v1",
        callable: ->(input) do
          report_calls += 1
          DAG::Success.new(value: "report:#{input[:process]}:v#{report_calls}")
        end
      }
    )

    initial = DAG::Workflow::Runner.new(original,
      parallel: false,
      workflow_id: "wf-rerun-impact",
      execution_store: store).call

    replacement = build_test_workflow(
      normalize: {
        type: :ruby,
        resume_key: "normalize-v1",
        callable: ->(input) do
          normalize_calls += 1
          DAG::Success.new(value: "#{input[:source]}-normalized")
        end
      },
      summarize: {
        type: :ruby,
        depends_on: [:normalize],
        resume_key: "summarize-v1",
        callable: ->(input) do
          summarize_calls += 1
          DAG::Success.new(value: input[:normalize].upcase)
        end
      }
    )

    mutated = DAG::Workflow.replace_subtree(
      original,
      root_node: :process,
      replacement: replacement,
      reconnect: [{from: :summarize, to: :report, metadata: {as: :process}}]
    )

    impact = DAG::Workflow.apply_subtree_replacement_impact(
      workflow_id: "wf-rerun-impact",
      definition: original,
      root_node: :process,
      execution_store: store,
      cause: {source: :planner},
      new_definition: mutated
    )

    rerun = DAG::Workflow::Runner.new(mutated,
      parallel: false,
      workflow_id: "wf-rerun-impact",
      execution_store: store).call

    assert initial.success?
    assert rerun.success?
    assert_equal [[:process]], impact[:obsolete_nodes]
    assert_equal [[:report]], impact[:stale_nodes]
    assert_equal 1, source_calls
    assert_equal 1, process_calls
    assert_equal 1, normalize_calls
    assert_equal 1, summarize_calls
    assert_equal 2, report_calls
    assert_equal "payload", rerun.outputs[:source].value
    assert_equal "PAYLOAD-NORMALIZED", rerun.outputs[:summarize].value
    assert_equal "report:PAYLOAD-NORMALIZED:v2", rerun.outputs[:report].value

    source_history = store.load_output(workflow_id: "wf-rerun-impact", node_path: [:source], version: :all)
    report_history = store.load_output(workflow_id: "wf-rerun-impact", node_path: [:report], version: :all)

    assert_equal [1], source_history.map { |entry| entry[:version] }
    assert_equal [1, 2], report_history.map { |entry| entry[:version] }
    assert_equal [true, false], report_history.map { |entry| entry[:superseded] }
  end

  def test_apply_subtree_replacement_impact_threads_root_input_into_mutated_fingerprint
    source_calls = 0
    normalize_calls = 0
    summarize_calls = 0
    report_calls = 0
    store = build_memory_store
    root_input = {seed: 1}

    original = build_test_workflow(
      source: {
        type: :ruby,
        resume_key: "source-v1",
        callable: ->(input) do
          source_calls += 1
          DAG::Success.new(value: "seed-#{input[:seed]}")
        end
      },
      process: {
        type: :ruby,
        depends_on: [:source],
        resume_key: "process-v1",
        callable: ->(input) { DAG::Success.new(value: input[:source].upcase) }
      },
      report: {
        type: :ruby,
        depends_on: [:process],
        resume_key: "report-v1",
        callable: ->(input) do
          report_calls += 1
          DAG::Success.new(value: "#{input[:process]}:report-#{report_calls}")
        end
      }
    )

    initial = DAG::Workflow::Runner.new(original,
      parallel: false,
      workflow_id: "wf-rerun-impact-root-input",
      execution_store: store,
      root_input: root_input).call

    replacement = build_test_workflow(
      normalize: {
        type: :ruby,
        resume_key: "normalize-v1",
        callable: ->(input) do
          normalize_calls += 1
          DAG::Success.new(value: "#{input[:source]}-normalized")
        end
      },
      summarize: {
        type: :ruby,
        depends_on: [:normalize],
        resume_key: "summarize-v1",
        callable: ->(input) do
          summarize_calls += 1
          DAG::Success.new(value: input[:normalize].upcase)
        end
      }
    )

    mutated = DAG::Workflow.replace_subtree(
      original,
      root_node: :process,
      replacement: replacement,
      reconnect: [{from: :summarize, to: :report, metadata: {as: :process}}]
    )

    impact = DAG::Workflow.apply_subtree_replacement_impact(
      workflow_id: "wf-rerun-impact-root-input",
      definition: original,
      root_node: :process,
      execution_store: store,
      new_definition: mutated,
      root_input: root_input
    )

    rerun = DAG::Workflow::Runner.new(mutated,
      parallel: false,
      workflow_id: "wf-rerun-impact-root-input",
      execution_store: store,
      root_input: root_input).call

    assert initial.success?
    assert rerun.success?
    assert_equal [[:process]], impact[:obsolete_nodes]
    assert_equal [[:report]], impact[:stale_nodes]
    assert_equal 1, source_calls
    assert_equal 1, normalize_calls
    assert_equal 1, summarize_calls
    assert_equal 2, report_calls
    assert_equal "SEED-1-NORMALIZED:report-2", rerun.outputs[:report].value
  end

  def test_apply_subtree_replacement_impact_rejects_non_definition_new_definition
    definition = build_test_workflow(
      process: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :process) }}
    )
    store = build_memory_store
    store.begin_run(
      workflow_id: "wf-invalid-new-definition",
      definition_fingerprint: "fp-1",
      node_paths: [[:process]]
    )
    store.set_node_state(workflow_id: "wf-invalid-new-definition", node_path: [:process], state: :completed)

    error = assert_raises(ArgumentError) do
      DAG::Workflow.apply_subtree_replacement_impact(
        workflow_id: "wf-invalid-new-definition",
        definition: definition,
        root_node: :process,
        execution_store: store,
        new_definition: Object.new
      )
    end

    assert_match(/new_definition must be a DAG::Workflow::Definition/, error.message)
  end

  def test_subtree_replacement_rerun_works_with_file_store
    source_calls = 0
    process_calls = 0
    normalize_calls = 0
    summarize_calls = 0
    report_calls = 0

    original = build_test_workflow(
      source: {
        type: :ruby,
        resume_key: "source-v1",
        callable: ->(_input) do
          source_calls += 1
          DAG::Success.new(value: "payload")
        end
      },
      process: {
        type: :ruby,
        depends_on: [:source],
        resume_key: "process-v1",
        callable: ->(input) do
          process_calls += 1
          DAG::Success.new(value: input[:source].upcase)
        end
      },
      report: {
        type: :ruby,
        depends_on: [:process],
        resume_key: "report-v1",
        callable: ->(input) do
          report_calls += 1
          DAG::Success.new(value: "report:#{input[:process]}:v#{report_calls}")
        end
      }
    )

    replacement = build_test_workflow(
      normalize: {
        type: :ruby,
        resume_key: "normalize-v1",
        callable: ->(input) do
          normalize_calls += 1
          DAG::Success.new(value: "#{input[:source]}-normalized")
        end
      },
      summarize: {
        type: :ruby,
        depends_on: [:normalize],
        resume_key: "summarize-v1",
        callable: ->(input) do
          summarize_calls += 1
          DAG::Success.new(value: input[:normalize].upcase)
        end
      }
    )

    mutated = DAG::Workflow.replace_subtree(
      original,
      root_node: :process,
      replacement: replacement,
      reconnect: [{from: :summarize, to: :report, metadata: {as: :process}}]
    )

    Dir.mktmpdir("dag-mutation-rerun-file-store") do |dir|
      first_store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
      second_store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)

      initial = DAG::Workflow::Runner.new(original,
        parallel: false,
        workflow_id: "wf-rerun-impact-file",
        execution_store: first_store).call

      impact = DAG::Workflow.apply_subtree_replacement_impact(
        workflow_id: "wf-rerun-impact-file",
        definition: original,
        root_node: :process,
        execution_store: second_store,
        cause: {source: :planner},
        new_definition: mutated
      )

      rerun = DAG::Workflow::Runner.new(mutated,
        parallel: false,
        workflow_id: "wf-rerun-impact-file",
        execution_store: DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)).call

      assert initial.success?
      assert rerun.success?
      assert_equal [[:process]], impact[:obsolete_nodes]
      assert_equal [[:report]], impact[:stale_nodes]
      assert_equal 1, source_calls
      assert_equal 1, process_calls
      assert_equal 1, normalize_calls
      assert_equal 1, summarize_calls
      assert_equal 2, report_calls
      assert_equal "payload", rerun.outputs[:source].value
      assert_equal "PAYLOAD-NORMALIZED", rerun.outputs[:summarize].value
      assert_equal "report:PAYLOAD-NORMALIZED:v2", rerun.outputs[:report].value
    end
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
