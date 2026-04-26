# frozen_string_literal: true

require "digest"
require "json"

module DAG
  module Adapters
    module Stdlib
      # Deterministic SHA256 over a JSON-canonicalized form of the value:
      # symbols stringified, hash keys deduplicated and sorted, arrays kept in
      # order, floats rejected if non-finite. The same value always produces
      # the same digest regardless of insertion order.
      class Fingerprint
        include Ports::Fingerprint

        def initialize
          freeze
        end

        def compute(value)
          DAG.json_safe!(value)
          Digest::SHA256.hexdigest(JSON.generate(deep_canonical(value)))
        end

        private

        def deep_canonical(value)
          case value
          when Hash
            seen = {}
            pairs = value.map do |k, v|
              key = k.to_s
              raise ArgumentError, "canonical key collision: #{key.inspect}" if seen[key]
              seen[key] = true
              [key, deep_canonical(v)]
            end
            pairs.sort_by(&:first).to_h
          when Array
            value.map { |v| deep_canonical(v) }
          when Symbol
            value.to_s
          when Float
            raise ArgumentError, "non-finite float" if value.nan? || value.infinite?
            value
          when String, Integer, TrueClass, FalseClass, NilClass
            value
          end
        end
      end
    end
  end
end
