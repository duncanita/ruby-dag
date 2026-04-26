# frozen_string_literal: true

require "json"

module DAG
  module Adapters
    module Stdlib
      # JSON-based serializer enforcing JSON-safety on the way in. Symbols
      # are stringified by `JSON.generate` but `load` returns string keys —
      # callers that need symbol keys must convert.
      class Serializer
        include Ports::Serializer

        def initialize
          freeze
        end

        def dump(value)
          DAG.json_safe!(value)
          JSON.generate(value)
        end

        def load(blob)
          JSON.parse(blob)
        end
      end
    end
  end
end
