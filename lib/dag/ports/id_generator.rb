# frozen_string_literal: true

module DAG
  module Ports
    # Unique-id generator port. Used by the Runner to mint workflow ids,
    # attempt ids, and revision-scoped identifiers.
    #
    # @api public
    module IdGenerator
      # @return [String] a fresh unique id
      def call
        raise PortNotImplementedError
      end
    end
  end
end
