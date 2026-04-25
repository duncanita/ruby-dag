# frozen_string_literal: true

require_relative "test_helper"

class TraceRecorderTest < Minitest::Test
  include TestHelpers

  def test_build_trace_entries_for_task_converts_attempt_trace_entries_and_preserves_child_trace
    recorder = DAG::Workflow::TraceRecorder.new(callbacks: DAG::Workflow::RunCallbacks.new)
    task = build_task(
      input_keys: [:payload],
      attempt_log: [
        DAG::Workflow::AttemptTraceEntry.new(
          node_path: [:fetch],
          started_at: 1.0,
          finished_at: 2.0,
          duration_ms: 1000.0,
          status: :failure,
          attempt: 1
        ),
        DAG::Workflow::AttemptTraceEntry.new(
          node_path: [:fetch],
          started_at: 3.0,
          finished_at: 4.0,
          duration_ms: 1000.0,
          status: :success,
          attempt: 2
        ),
        DAG::Workflow::TraceEntry.new(
          name: :"fetch.child",
          layer: 1,
          started_at: 3.2,
          finished_at: 3.8,
          duration_ms: 600.0,
          status: :success,
          input_keys: [:payload],
          attempt: 1,
          retried: false
        )
      ]
    )

    outcome = DAG::Workflow::Parallel::StepOutcome.new(
      name: :fetch, result: DAG::Success.new(value: "ok"),
      started_at: 3.0, finished_at: 4.0, duration_ms: 1000.0
    )
    entries = recorder.build_trace_entries_for_task(
      task: task,
      layer_index: 0,
      outcome: outcome,
      lifecycle_payload: nil
    )

    assert_equal 3, entries.size
    assert_equal [1, 2], entries.first(2).map(&:attempt)
    assert_equal [true, false], entries.first(2).map(&:retried)
    assert_equal [:failure, :success], entries.first(2).map(&:status)
    assert_equal :"fetch.child", entries.last.name
  end

  private

  def build_task(input_keys:, attempt_log:)
    execution = DAG::Workflow::StepExecution.new(
      workflow_id: "wf-trace-recorder",
      node_path: [:fetch],
      attempt: 1,
      deadline: nil,
      depth: 0,
      parallel: :sequential,
      execution_store: nil,
      event_bus: attempt_log
    )

    Data.define(:execution, :input_keys, :attempt_log).new(
      execution: execution,
      input_keys: input_keys,
      attempt_log: attempt_log
    )
  end
end
