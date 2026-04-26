# frozen_string_literal: true

module DAG
  module Ports
    module EventBus
      def publish(event)
        raise PortNotImplementedError
      end

      def subscribe(&block)
        raise PortNotImplementedError
      end
    end
  end
end
