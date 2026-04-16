# frozen_string_literal: true

# Logging middleware: structured events plus human-readable formatting.
#
# Run: ruby -Ilib examples/logging_middleware.rb

require "dag"
require "json"

logged_events = []

definition = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :ruby,
    callable: ->(_input) { DAG::Success.new(value: "payload") }
  },
  transform: {
    type: :ruby,
    depends_on: [:fetch],
    callable: ->(input) { DAG::Success.new(value: input[:fetch].upcase) }
  }
)

logger = lambda do |event|
  logged_events << event
  puts JSON.generate(event.transform_keys(&:to_s))
end

result = DAG::Workflow::Runner.new(definition,
  parallel: false,
  workflow_id: "example-logging",
  middleware: [DAG::Workflow::LoggingMiddleware.new(logger: logger)]).call

puts
puts "=== Structured Log Summary ==="
puts "Status: #{result.status}"
puts "Events captured: #{logged_events.size}"
puts "First event kind: #{logged_events.first[:event]}"
puts "Last event status: #{logged_events.last[:status]}"
puts "Final output: #{result.outputs[:transform].value}"
puts "Formatted sample: #{DAG::Workflow::LoggingMiddleware.format(logged_events.last)}"
