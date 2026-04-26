# frozen_string_literal: true

module DAG
  module Ports
    module Clock
      def now
        raise PortNotImplementedError
      end

      def now_ms
        raise PortNotImplementedError
      end

      def monotonic_ms
        raise PortNotImplementedError
      end
    end
  end
end
