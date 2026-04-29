# frozen_string_literal: true

module DAG
  module Ports
    # Deterministic fingerprint port. Used to fingerprint definitions and
    # other structurally hashable values; the function must be stable
    # across processes and Ruby releases.
    #
    # @api public
    module Fingerprint
      # @param value [Object] JSON-safe input
      # @return [String] hex digest
      def compute(value)
        raise PortNotImplementedError
      end
    end
  end
end
