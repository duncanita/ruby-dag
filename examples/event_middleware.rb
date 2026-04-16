# frozen_string_literal: true

# Event middleware: emit workflow events from successful step attempts.
#
# Run: ruby -Ilib examples/event_middleware.rb

require "dag"

class MemoryEventBus < DAG::Workflow::EventBus
  attr_reader :events

  def initialize
    @events = []
  end

  def publish(event)
    @events << event
  end
end

bus = MemoryEventBus.new

definition = DAG::Workflow::Loader.from_hash(
  monitor: {
    type: :ruby,
    emit_events: [
      {name: :anomaly_detected, if: ->(result) { result.value[:score] > 0.8 }},
      {name: :high_priority, if: ->(result) { result.value[:priority] == :high }}
    ],
    callable: ->(_input) { DAG::Success.new(value: {score: 0.91, priority: :high}) }
  }
)

result = DAG::Workflow::Runner.new(definition,
  parallel: false,
  workflow_id: "example-events",
  middleware: [DAG::Workflow::EventMiddleware.new(event_bus: bus)]).call

puts "=== Event Summary ==="
puts "Status: #{result.status}"
puts "Events captured: #{bus.events.size}"
puts "Event names: #{bus.events.map(&:name).join(", ")}"
puts "Payload priority: #{bus.events.first.payload[:priority]}"
puts "Node path: #{bus.events.first.node_path.join(".")}"
