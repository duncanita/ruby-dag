# frozen_string_literal: true

require_relative "test_helper"

class RetryTest < Minitest::Test
  include TestHelpers

  def test_retry_middleware_retries_until_success_and_records_each_attempt
    attempts = 0
    defn = build_test_workflow(
      flaky: {
        type: :ruby,
        callable: ->(_input) do
          attempts += 1
          if attempts < 3
            DAG::Failure.new(error: {code: :exec_failed, attempt: attempts})
          else
            DAG::Success.new(value: "ok")
          end
        end,
        retry: {
          max_attempts: 3,
          backoff: :fixed,
          base_delay: 0.0,
          retry_on: [:exec_failed]
        }
      }
    )

    middleware = DAG::Workflow::RetryMiddleware.new(sleeper: ->(_seconds) {})
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      middleware: [middleware]).call

    assert result.success?
    assert_equal 3, attempts

    trace = result.trace.select { |entry| entry.name == :flaky }
    assert_equal 3, trace.size
    assert_equal [1, 2, 3], trace.map(&:attempt)
    assert_equal [:failure, :failure, :success], trace.map(&:status)
    assert_equal [true, true, false], trace.map(&:retried)
  end

  def test_retry_middleware_does_not_retry_non_matching_error_codes
    attempts = 0
    defn = build_test_workflow(
      nope: {
        type: :ruby,
        callable: ->(_input) do
          attempts += 1
          DAG::Failure.new(error: {code: :other_failure})
        end,
        retry: {
          max_attempts: 3,
          backoff: :fixed,
          base_delay: 0.0,
          retry_on: [:exec_failed]
        }
      }
    )

    middleware = DAG::Workflow::RetryMiddleware.new(sleeper: ->(_seconds) {})
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      middleware: [middleware]).call

    assert result.failure?
    assert_equal 1, attempts
    assert_equal :nope, result.error[:failed_node]
    assert_equal :other_failure, result.error[:step_error][:code]
    assert_equal [{code: :other_failure}], result.error[:step_error][:attempt_errors]

    trace = result.trace.select { |entry| entry.name == :nope }
    assert_equal 1, trace.size
    assert_equal [1], trace.map(&:attempt)
    assert_equal [false], trace.map(&:retried)
  end

  def test_retry_middleware_returns_timeout_failure_when_backoff_exceeds_deadline
    clock = build_clock(mono_time: 0.0)
    attempts = 0
    defn = build_test_workflow(
      deadline: {
        type: :ruby,
        callable: ->(_input) do
          attempts += 1
          DAG::Failure.new(error: {code: :exec_failed, attempt: attempts})
        end,
        retry: {
          max_attempts: 3,
          backoff: :fixed,
          base_delay: 1.0,
          retry_on: [:exec_failed]
        }
      }
    )

    middleware = DAG::Workflow::RetryMiddleware.new(clock: clock, sleeper: ->(seconds) { clock.advance(seconds) })
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      timeout: 0.5,
      clock: clock,
      middleware: [middleware]).call

    assert result.failure?
    assert_equal 1, attempts
    assert_equal :deadline, result.error[:failed_node]
    assert_equal :workflow_timeout, result.error[:step_error][:code]
    assert_equal [{code: :exec_failed, attempt: 1}], result.error[:step_error][:attempt_errors]

    trace = result.trace.select { |entry| entry.name == :deadline }
    assert_equal 1, trace.size
    assert_equal [1], trace.map(&:attempt)
    assert_equal [false], trace.map(&:retried)
  end

  def test_retry_middleware_accumulates_attempt_errors_in_order_on_final_failure
    attempts = 0
    defn = build_test_workflow(
      exhausted: {
        type: :ruby,
        callable: ->(_input) do
          attempts += 1
          DAG::Failure.new(error: {code: :exec_failed, ordinal: attempts})
        end,
        retry: {
          max_attempts: 3,
          backoff: :fixed,
          base_delay: 0.0,
          retry_on: [:exec_failed]
        }
      }
    )

    middleware = DAG::Workflow::RetryMiddleware.new(sleeper: ->(_seconds) {})
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      middleware: [middleware]).call

    assert result.failure?
    assert_equal 3, attempts
    assert_equal :exec_failed, result.error[:step_error][:code]
    assert_equal [1, 2, 3], result.error[:step_error][:attempt_errors].map { |entry| entry[:ordinal] }

    trace = result.trace.select { |entry| entry.name == :exhausted }
    assert_equal 3, trace.size
    assert_equal [1, 2, 3], trace.map(&:attempt)
    assert_equal [true, true, false], trace.map(&:retried)
  end

  def test_retry_middleware_uses_exponential_backoff_and_max_delay_cap
    attempts = 0
    sleeps = []
    defn = build_test_workflow(
      capped: {
        type: :ruby,
        callable: ->(_input) do
          attempts += 1
          if attempts < 4
            DAG::Failure.new(error: {code: :exec_failed})
          else
            DAG::Success.new(value: "ok")
          end
        end,
        retry: {
          max_attempts: 4,
          backoff: :exponential,
          base_delay: 0.5,
          max_delay: 0.75,
          retry_on: [:exec_failed]
        }
      }
    )

    middleware = DAG::Workflow::RetryMiddleware.new(sleeper: ->(seconds) { sleeps << seconds })
    result = DAG::Workflow::Runner.new(defn.graph, defn.registry,
      parallel: false,
      middleware: [middleware]).call

    assert result.success?
    assert_equal 4, attempts
    assert_equal [0.5, 0.75, 0.75], sleeps
  end
end
