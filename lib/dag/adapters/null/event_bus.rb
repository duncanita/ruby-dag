# frozen_string_literal: true

module DAG
  module Adapters
    module Null
      # Drops every event silently. The optional `logger:` keyword forwards
      # to `logger.debug` for diagnostic taps.
      class EventBus
        include Ports::EventBus

        def initialize(logger: nil)
          @logger = logger
          freeze
        end

        def publish(event)
          @logger&.debug("[dag] #{event.inspect}")
          nil
        end

        def subscribe(&block)
          nil
        end
      end
    end
  end
end
