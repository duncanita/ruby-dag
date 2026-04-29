# frozen_string_literal: true

module DAG
  module Adapters
    # No-op adapters useful for tests, scripts, and consumers that opt out
    # of a given subsystem.
    # @api public
    module Null
      # Drops every event silently. The optional `logger:` keyword forwards
      # to `logger.debug` for diagnostic taps.
      # @api public
      class EventBus
        include Ports::EventBus

        # @param logger [#debug, nil] optional sink for diagnostic logging
        def initialize(logger: nil)
          @logger = logger
          freeze
        end

        # @param event [DAG::Event]
        # @return [nil]
        def publish(event)
          @logger&.debug("[dag] #{event.inspect}")
          nil
        end

        # No-op. The null bus has no subscribers.
        # @return [nil]
        def subscribe(&block)
          nil
        end
      end
    end
  end
end
