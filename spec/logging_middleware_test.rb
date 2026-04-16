# frozen_string_literal: true

require_relative "test_helper"

class LoggingMiddlewareTest < Minitest::Test
  include TestHelpers

  def test_logs_structured_start_and_finish_for_successful_attempt
    events = []
    middleware = DAG::Workflow::LoggingMiddleware.new(logger: ->(event) { events << event })
    execution = build_execution(attempt: 2)

    result = middleware.call(build_step, {source: "value"}, context: nil, execution: execution, next_step: lambda do |_step, _input, context:, execution:|
      assert_nil context
      assert_equal 2, execution.attempt
      DAG::Success.new(value: "ok")
    end)

    assert result.success?
    assert_equal [
      {
        event: :starting,
        step_name: :child,
        step_type: :ruby,
        workflow_id: "wf-logging",
        node_path: [:parent, :child],
        attempt: 2,
        depth: 1,
        parallel: :sequential,
        input_keys: [:source]
      },
      {
        event: :finished,
        step_name: :child,
        step_type: :ruby,
        workflow_id: "wf-logging",
        node_path: [:parent, :child],
        attempt: 2,
        depth: 1,
        parallel: :sequential,
        status: :ok
      }
    ], events
  end

  def test_logs_failure_result_as_structured_fail_event
    events = []
    middleware = DAG::Workflow::LoggingMiddleware.new(logger: ->(event) { events << event })

    result = middleware.call(build_step, {}, context: nil, execution: build_execution, next_step: lambda do |_step, _input, context:, execution:|
      assert_nil context
      assert_equal [:parent, :child], execution.node_path
      DAG::Failure.new(error: {code: :boom})
    end)

    assert result.failure?
    assert_equal :starting, events[0][:event]
    assert_equal [], events[0][:input_keys]
    assert_equal :finished, events[1][:event]
    assert_equal :fail, events[1][:status]
  end

  def test_logs_raised_errors_before_reraising
    events = []
    middleware = DAG::Workflow::LoggingMiddleware.new(logger: ->(event) { events << event })

    error = assert_raises(RuntimeError) do
      middleware.call(build_step, {}, context: nil, execution: build_execution, next_step: lambda do |_step, _input, context:, execution:|
        assert_nil context
        assert_equal 1, execution.attempt
        raise "boom"
      end)
    end

    assert_equal "boom", error.message
    assert_equal :starting, events[0][:event]
    assert_equal :raised, events[1][:event]
    assert_equal "RuntimeError", events[1][:error_class]
    assert_equal "boom", events[1][:error_message]
  end

  def test_format_produces_human_readable_line
    formatted = DAG::Workflow::LoggingMiddleware.format(
      event: :finished,
      node_path: [:parent, :child],
      attempt: 3,
      step_type: :ruby,
      status: :ok
    )

    assert_equal "finished parent.child attempt=3 step_type=ruby status=ok", formatted
  end

  def test_runner_uses_logging_middleware_when_configured
    events = []
    definition = build_test_workflow(
      wrapped: {type: :ruby, callable: ->(_input) { DAG::Success.new(value: "core") }}
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      middleware: [DAG::Workflow::LoggingMiddleware.new(logger: ->(event) { events << event })]).call

    assert result.success?
    assert_equal :starting, events[0][:event]
    assert_equal :wrapped, events[0][:step_name]
    assert_equal [], events[0][:input_keys]
    assert_equal :finished, events[1][:event]
    assert_equal :ok, events[1][:status]
  end

  private

  def build_execution(attempt: 1)
    DAG::Workflow::StepExecution.new(
      workflow_id: "wf-logging",
      node_path: [:parent, :child],
      attempt: attempt,
      deadline: nil,
      depth: 1,
      parallel: :sequential,
      execution_store: nil,
      event_bus: []
    )
  end

  def build_step
    DAG::Workflow::Step.new(name: :child, type: :ruby, resume_key: "child-v1", callable: ->(_input) { DAG::Success.new(value: "ok") })
  end
end
