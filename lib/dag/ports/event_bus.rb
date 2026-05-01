# frozen_string_literal: true

module DAG
  module Ports
    # Live event bus port. Adapters fan out events that storage has already
    # durably appended; the bus is not the durability boundary.
    #
    # @api public
    module EventBus
      # Publish a stamped event to every subscriber.
      #
      # @param event [DAG::Event]
      # @return [void]
      def publish(event)
        raise PortNotImplementedError
      end

      # Register a subscriber. The block receives each future event and the
      # return value unsubscribes it. Null adapters may return a no-op Proc.
      #
      # @yieldparam event [DAG::Event]
      # @return [Proc]
      def subscribe(&block)
        raise PortNotImplementedError
      end
    end
  end
end
