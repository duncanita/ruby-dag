# frozen_string_literal: true

module DAG
  module Ports
    module Serializer
      def dump(value)
        raise PortNotImplementedError
      end

      def load(blob)
        raise PortNotImplementedError
      end
    end
  end
end
