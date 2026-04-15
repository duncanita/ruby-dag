# frozen_string_literal: true

require_relative "test_helper"

class StepMiddlewareTest < Minitest::Test
  def test_base_middleware_delegates_to_next_step
    middleware = DAG::Workflow::StepMiddleware.new
    step = Object.new
    input = {source: "value"}
    context = {request_id: "abc"}
    execution = Object.new
    expected = DAG::Success.new(value: :ok)
    received = nil

    result = middleware.call(step, input, context: context, execution: execution, next_step: lambda { |passed_step, passed_input, context:, execution:|
      received = [passed_step, passed_input, context, execution]
      expected
    })

    assert_same expected, result
    assert_equal [step, input, context, execution], received
  end
end
