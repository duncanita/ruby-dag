# frozen_string_literal: true

# Nested event middleware: emit workflow events from successful child steps inside
# a sub-workflow and keep the full namespaced node_path.
#
# Run: ruby -Ilib examples/nested_event_middleware.rb

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

child = DAG::Workflow::Loader.from_hash(
  analyze: {
    type: :ruby,
    emit_events: [
      {
        name: :child_ready,
        payload: ->(result) { {normalized: result.value[:normalized], source: :child} },
        metadata: ->(_result) { {scope: :nested, producer: :analyze} }
      }
    ],
    callable: ->(_input) { DAG::Success.new(value: {normalized: "HELLO"}) }
  }
)

parent = DAG::Workflow::Loader.from_hash(
  process: {
    type: :sub_workflow,
    definition: child,
    output_key: :analyze
  }
)

result = DAG::Workflow::Runner.new(parent,
  parallel: false,
  workflow_id: "example-nested-events",
  event_bus: bus,
  middleware: [DAG::Workflow::EventMiddleware.new]).call

puts "=== Nested Event Summary ==="
puts "Status: #{result.status}"
puts "Events captured: #{bus.events.size}"
puts "Event names: #{bus.events.map(&:name).join(", ")}"
puts "Event node path: #{bus.events.first.node_path.join(".")}"
puts "Event payload source: #{bus.events.first.payload[:source]}"
puts "Event payload normalized: #{bus.events.first.payload[:normalized]}"
puts "Event metadata scope: #{bus.events.first.metadata[:scope]}"
puts "Event metadata producer: #{bus.events.first.metadata[:producer]}"
