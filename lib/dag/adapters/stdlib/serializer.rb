# frozen_string_literal: true

require "json"

module DAG
  module Adapters
    module Stdlib
      # JSON-based serializer enforcing JSON-safety on the way in. Symbols
      # are stringified by `JSON.generate` but `load` returns string keys —
      # callers that need symbol keys must convert.
      # @api public
      class Serializer
        include Ports::Serializer

        def initialize
          freeze
        end

        # @param value [Object] JSON-safe value
        # @return [String]
        # @raise [ArgumentError] when `value` is not JSON-safe
        def dump(value)
          DAG.json_safe!(value)
          JSON.generate(value)
        end

        # @param blob [String]
        # @return [Object] parsed JSON value (string keys)
        def load(blob)
          JSON.parse(blob)
        end
      end
    end
  end
end
