# frozen_string_literal: true

# Logging middleware: failure results and raised middleware exceptions.
#
# Run: ruby -Ilib examples/logging_middleware_failures.rb

require "dag"
require "json"

failure_events = []
raised_events = []

failure_logger = lambda do |event|
  failure_events << event
  puts JSON.generate(event.transform_keys(&:to_s))
end

raised_logger = lambda do |event|
  raised_events << event
  puts JSON.generate(event.transform_keys(&:to_s))
end

failure_definition = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :ruby,
    callable: ->(_input) { DAG::Success.new(value: "payload") }
  },
  validate: {
    type: :ruby,
    depends_on: [:fetch],
    callable: ->(_input) { DAG::Failure.new(error: {code: :invalid_payload, message: "payload rejected"}) }
  }
)

failure_result = DAG::Workflow::Runner.new(failure_definition,
  parallel: false,
  workflow_id: "example-logging-failure",
  middleware: [DAG::Workflow::LoggingMiddleware.new(logger: failure_logger)]).call

puts
puts "=== Failure Result Summary ==="
puts "Status: #{failure_result.status}"
puts "Failed node: #{failure_result.error[:failed_node]}"
puts "Step error code: #{failure_result.error[:step_error][:code]}"
puts "Logged finish status: #{failure_events.last[:status]}"
puts "Formatted sample: #{DAG::Workflow::LoggingMiddleware.format(failure_events.last)}"
puts

raising_middleware_class = Class.new(DAG::Workflow::StepMiddleware) do
  def call(step, input, context:, execution:, next_step:)
    raise "middleware kaboom for #{step.name}"
  end
end

raised_definition = DAG::Workflow::Loader.from_hash(
  explode: {
    type: :ruby,
    callable: ->(_input) { DAG::Success.new(value: "never reached") }
  }
)

raised_result = DAG::Workflow::Runner.new(raised_definition,
  parallel: false,
  workflow_id: "example-logging-raised",
  middleware: [
    DAG::Workflow::LoggingMiddleware.new(logger: raised_logger),
    raising_middleware_class.new
  ]).call

puts "=== Raised Exception Summary ==="
puts "Status: #{raised_result.status}"
puts "Failed node: #{raised_result.error[:failed_node]}"
puts "Step error code: #{raised_result.error[:step_error][:code]}"
puts "Raised error class: #{raised_events.last[:error_class]}"
puts "Raised error message: #{raised_events.last[:error_message]}"
puts "Formatted sample: #{DAG::Workflow::LoggingMiddleware.format(raised_events.last)}"
