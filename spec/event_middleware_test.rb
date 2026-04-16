# frozen_string_literal: true

require_relative "test_helper"

class EventMiddlewareTest < Minitest::Test
  include TestHelpers

  MemoryEventBus = Class.new(DAG::Workflow::EventBus) do
    attr_reader :events

    def initialize
      @events = []
    end

    def publish(event)
      @events << event
    end
  end

  def test_emits_configured_events_for_successful_attempts
    clock = build_clock(wall_time: Time.utc(2026, 4, 16, 12, 0, 0))
    bus = MemoryEventBus.new
    middleware = DAG::Workflow::EventMiddleware.new(event_bus: bus, clock: clock)

    result = middleware.call(build_step(emit_events: [
      {name: :anomaly_detected, if: ->(attempt_result) { attempt_result.value[:score] > 0.8 }},
      {name: :high_priority, if: ->(attempt_result) { attempt_result.value[:priority] == :high }}
    ]), {}, context: nil, execution: build_execution, next_step: lambda do |_step, _input, context:, execution:|
      assert_nil context
      assert_equal [:monitor], execution.node_path
      DAG::Success.new(value: {score: 0.91, priority: :high})
    end)

    assert result.success?
    assert_equal %i[anomaly_detected high_priority], bus.events.map(&:name)
    assert_equal "wf-events", bus.events.first.workflow_id
    assert_equal [:monitor], bus.events.first.node_path
    assert_equal({score: 0.91, priority: :high}, bus.events.first.payload)
    assert_equal Time.utc(2026, 4, 16, 12, 0, 0), bus.events.first.emitted_at
  end

  def test_does_not_emit_events_for_failed_attempts
    bus = MemoryEventBus.new
    middleware = DAG::Workflow::EventMiddleware.new(event_bus: bus, clock: build_clock)

    result = middleware.call(build_step(emit_events: [
      {name: :anomaly_detected, if: ->(_attempt_result) { true }}
    ]), {}, context: nil, execution: build_execution, next_step: lambda do |_step, _input, context:, execution:|
      assert_nil context
      assert_equal 1, execution.attempt
      DAG::Failure.new(error: {code: :boom})
    end)

    assert result.failure?
    assert_empty bus.events
  end

  def test_runner_uses_runner_event_bus_for_event_middleware
    bus = MemoryEventBus.new
    definition = build_test_workflow(
      monitor: {
        type: :ruby,
        emit_events: [{name: :ready, if: ->(attempt_result) { attempt_result.value == "ok" }}],
        callable: ->(_input) { DAG::Success.new(value: "ok") }
      }
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      workflow_id: "wf-runner-events",
      event_bus: bus,
      middleware: [DAG::Workflow::EventMiddleware.new(clock: build_clock)]).call

    assert_equal :completed, result.status
    assert_equal [:ready], bus.events.map(&:name)
    assert_equal "ok", bus.events.first.payload
    assert_equal "wf-runner-events", bus.events.first.workflow_id
  end

  def test_runner_emits_only_after_final_retry_success
    bus = MemoryEventBus.new
    attempts = 0
    definition = build_test_workflow(
      monitor: {
        type: :ruby,
        emit_events: [{name: :ready, if: ->(attempt_result) { attempt_result.value == "ok" }}],
        retry: {max_attempts: 2},
        callable: ->(_input) do
          attempts += 1
          next DAG::Failure.new(error: {code: :flaky}) if attempts == 1

          DAG::Success.new(value: "ok")
        end
      }
    )

    result = DAG::Workflow::Runner.new(definition,
      parallel: false,
      workflow_id: "wf-retry-events",
      event_bus: bus,
      middleware: [
        DAG::Workflow::EventMiddleware.new(clock: build_clock),
        DAG::Workflow::RetryMiddleware.new(sleeper: ->(_seconds) {})
      ]).call

    assert_equal :completed, result.status
    assert_equal 2, attempts
    assert_equal [:ready], bus.events.map(&:name)
    assert_equal "ok", bus.events.first.payload
    assert_equal "wf-retry-events", bus.events.first.workflow_id
  end

  private

  def build_execution(attempt: 1)
    DAG::Workflow::StepExecution.new(
      workflow_id: "wf-events",
      node_path: [:monitor],
      attempt: attempt,
      deadline: nil,
      depth: 0,
      parallel: :sequential,
      execution_store: nil,
      event_bus: []
    )
  end

  def build_step(emit_events:)
    DAG::Workflow::Step.new(
      name: :monitor,
      type: :ruby,
      emit_events: emit_events,
      callable: ->(_input) { DAG::Success.new(value: "ok") }
    )
  end
end
