# frozen_string_literal: true

module DAG
  # Best-effort event publication. The event bus is a non-durable observer:
  # a publish failure must never fail the storage transaction it follows,
  # so every publisher swallows all StandardErrors through this single
  # helper instead of re-deriving the swallow semantics locally.
  # @api private
  module EventPublishing
    module_function

    # @param event_bus [Object] adapter implementing `Ports::EventBus`
    # @param event [DAG::Event]
    # @return [nil]
    def publish_quietly(event_bus, event)
      event_bus.publish(event)
      nil
    rescue
      nil
    end
  end
end
