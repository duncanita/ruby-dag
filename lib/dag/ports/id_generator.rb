# frozen_string_literal: true

module DAG
  module Ports
    module IdGenerator
      def call
        raise PortNotImplementedError
      end
    end
  end
end
