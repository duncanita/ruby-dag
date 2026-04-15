# frozen_string_literal: true

require_relative "test_helper"

class AttemptTraceMiddlewareTest < Minitest::Test
  include TestHelpers

  def test_records_successful_attempt_into_execution_event_bus
    clock = build_clock(mono_time: 10.0)
    middleware = DAG::Workflow::AttemptTraceMiddleware.new(clock: clock)
    events = []
    execution = build_execution(attempt: 2, event_bus: events)

    result = middleware.call(build_step, {}, context: nil, execution: execution, next_step: lambda do |_step, _input, context:, execution:|
      assert_nil context
      assert_equal 2, execution.attempt
      clock.advance_mono(0.25)
      DAG::Success.new(value: "ok")
    end)

    assert result.success?
    assert_equal 1, events.size
    assert_equal 2, events.first[:attempt]
    assert_equal [:demo], events.first[:node_path]
    assert_equal 10.0, events.first[:started_at]
    assert_equal 10.25, events.first[:finished_at]
    assert_equal 250.0, events.first[:duration_ms]
    assert_equal :success, events.first[:status]
    assert_equal false, events.first[:retried]
  end

  def test_records_failure_attempt_into_execution_event_bus
    clock = build_clock(mono_time: 5.0)
    middleware = DAG::Workflow::AttemptTraceMiddleware.new(clock: clock)
    events = []
    execution = build_execution(attempt: 1, event_bus: events)

    result = middleware.call(build_step, {}, context: nil, execution: execution, next_step: lambda do |_step, _input, context:, execution:|
      assert_nil context
      assert_equal 1, execution.attempt
      clock.advance_mono(0.1)
      DAG::Failure.new(error: {code: :boom})
    end)

    assert result.failure?
    assert_equal 1, events.size
    assert_equal :failure, events.first[:status]
    assert_equal 100.0, events.first[:duration_ms]
  end

  def test_skips_lifecycle_payload_results
    clock = build_clock(mono_time: 2.0)
    middleware = DAG::Workflow::AttemptTraceMiddleware.new(clock: clock)
    events = []
    execution = build_execution(attempt: 1, event_bus: events)

    result = middleware.call(build_step(type: :sub_workflow), {}, context: nil, execution: execution, next_step: lambda do |_step, _input, context:, execution:|
      assert_nil context
      assert_equal 1, execution.attempt
      clock.advance_mono(0.2)
      DAG::Success.new(value: {__sub_workflow_status__: :waiting})
    end)

    assert result.success?
    assert_equal [], events
  end

  private

  def build_execution(attempt:, event_bus:)
    DAG::Workflow::StepExecution.new(
      workflow_id: "wf-attempt-trace",
      node_path: [:demo],
      attempt: attempt,
      deadline: nil,
      depth: 0,
      parallel: :sequential,
      execution_store: nil,
      event_bus: event_bus
    )
  end

  def build_step(type: :ruby)
    DAG::Workflow::Step.new(name: :demo, type: type, resume_key: "demo-v1", callable: ->(_input) { DAG::Success.new(value: "ok") })
  end
end
