# frozen_string_literal: true

require_relative "test_helper"

class TaskCompletionHandlerTest < Minitest::Test
  include TestHelpers

  Task = Data.define(:name, :execution, :input_keys, :attempt_log)

  def test_handle_records_successful_task_result_into_trace_statuses_results_and_callbacks
    callback_events = []
    callbacks = DAG::Workflow::RunCallbacks.new(
      on_step_finish: ->(name, result) { callback_events << [name, result] }
    )
    trace_recorder = build_trace_recorder(
      entries: [build_trace_entry(name: :fetch, status: :success)],
      observed_status: :success
    )
    persistence = build_persistence_spy
    handler = DAG::Workflow::TaskCompletionHandler.new(
      trace_recorder: trace_recorder,
      execution_persistence: persistence,
      callbacks: callbacks
    )
    task = build_task(name: :fetch, node_path: [:fetch])
    result = DAG::Success.new(value: "ok")
    trace = []
    results = {}
    statuses = {}

    outcome = handler.handle(
      task: task,
      result: result,
      layer_index: 0,
      started_at: 1.0,
      finished_at: 2.0,
      duration_ms: 1000.0,
      trace: trace,
      results: results,
      statuses: statuses,
      lifecycle_payload: nil
    )

    assert_equal [], outcome.waiting_nodes
    refute outcome.paused
    assert_equal [:success], trace.map(&:status)
    assert_equal :success, statuses[:fetch]
    assert_equal result, results[:fetch]
    assert_equal [[:fetch, result]], callback_events
    assert_equal [[task, result, trace, false]], persistence.calls
  end

  def test_handle_lifecycle_result_returns_waiting_without_mutating_results_or_statuses
    callback_events = []
    callbacks = DAG::Workflow::RunCallbacks.new(
      on_step_finish: ->(name, result) { callback_events << [name, result] }
    )
    child_trace = [build_trace_entry(name: :"process.child", status: :success)]
    trace_recorder = build_trace_recorder(entries: child_trace, observed_status: :success)
    persistence = build_persistence_spy
    handler = DAG::Workflow::TaskCompletionHandler.new(
      trace_recorder: trace_recorder,
      execution_persistence: persistence,
      callbacks: callbacks,
      lifecycle_callback_result: ->(_lifecycle) { DAG::Success.new(value: nil) }
    )
    task = build_task(name: :process, node_path: [:process])
    result = DAG::Success.new(value: {__sub_workflow_status__: :waiting})
    trace = []
    results = {}
    statuses = {}
    lifecycle = {status: :waiting, waiting_nodes: [[:process, :child]]}

    outcome = handler.handle(
      task: task,
      result: result,
      layer_index: 1,
      started_at: 3.0,
      finished_at: 4.0,
      duration_ms: 1000.0,
      trace: trace,
      results: results,
      statuses: statuses,
      lifecycle_payload: lifecycle
    )

    assert_equal [[:process, :child]], outcome.waiting_nodes
    refute outcome.paused
    assert_equal child_trace, trace
    assert_equal({}, statuses)
    assert_equal({}, results)
    assert_equal 1, callback_events.size
    assert_equal :process, callback_events.first[0]
    assert_kind_of DAG::Success, callback_events.first[1]
    assert_nil callback_events.first[1].value
    assert_equal [[task, result, child_trace, true]], persistence.calls
  end

  private

  def build_task(name:, node_path:)
    execution = DAG::Workflow::StepExecution.new(
      workflow_id: "wf-task-handler",
      node_path: node_path,
      attempt: 1,
      deadline: nil,
      depth: 0,
      parallel: :sequential,
      execution_store: nil,
      event_bus: []
    )

    Task.new(name: name, execution: execution, input_keys: [:payload], attempt_log: [])
  end

  def build_trace_entry(name:, status:)
    DAG::Workflow::TraceEntry.new(
      name: name,
      layer: 0,
      started_at: 1.0,
      finished_at: 2.0,
      duration_ms: 1000.0,
      status: status,
      input_keys: [:payload],
      attempt: 1,
      retried: false
    )
  end

  def build_trace_recorder(entries:, observed_status:)
    Class.new do
      define_method(:initialize) do |entries:, observed_status:|
        @entries = entries
        @observed_status = observed_status
      end

      define_method(:build_trace_entries_for_task) do |**_kwargs|
        @entries
      end

      define_method(:observed_status_for_task) do |**_kwargs|
        @observed_status
      end
    end.new(entries: entries, observed_status: observed_status)
  end

  def build_persistence_spy
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def persist_step_result(task, result, entries, skip_result: false)
        @calls << [task, result, entries, skip_result]
      end
    end.new
  end
end
