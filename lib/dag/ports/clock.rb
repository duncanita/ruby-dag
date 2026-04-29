# frozen_string_literal: true

module DAG
  # Boundary ports the kernel depends on. Adapters under
  # {DAG::Adapters} implement these contracts.
  # @api public
  module Ports
    # Wall and monotonic clock port.
    #
    # @api public
    module Clock
      # @return [Time] wall-clock time
      def now
        raise PortNotImplementedError
      end

      # @return [Integer] wall-clock time in milliseconds since epoch
      def now_ms
        raise PortNotImplementedError
      end

      # @return [Integer] monotonic milliseconds since an arbitrary epoch
      def monotonic_ms
        raise PortNotImplementedError
      end
    end
  end
end
