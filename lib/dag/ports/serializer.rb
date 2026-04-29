# frozen_string_literal: true

module DAG
  module Ports
    # JSON-safe serializer port. Adapters round-trip JSON-safe values to
    # and from durable byte strings.
    #
    # @api public
    module Serializer
      # @param value [Object] JSON-safe value
      # @return [String]
      # @raise [DAG::SerializationError] when the value cannot be serialized
      def dump(value)
        raise PortNotImplementedError
      end

      # @param blob [String]
      # @return [Object] JSON-safe value
      # @raise [DAG::SerializationError] when the blob cannot be parsed
      def load(blob)
        raise PortNotImplementedError
      end
    end
  end
end
