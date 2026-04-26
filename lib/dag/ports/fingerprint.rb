# frozen_string_literal: true

module DAG
  module Ports
    module Fingerprint
      def compute(value)
        raise PortNotImplementedError
      end
    end
  end
end
