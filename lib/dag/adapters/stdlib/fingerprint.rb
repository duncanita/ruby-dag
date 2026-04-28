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
      # @api public
      class Fingerprint
        include Ports::Fingerprint

        def initialize
          freeze
        end

        # @param value [Object] JSON-safe input
        # @return [String] hex digest
        # @raise [ArgumentError] when `value` is not JSON-safe
        def compute(value)
          DAG.json_safe!(value)
          Digest::SHA256.hexdigest(JSON.generate(canonicalize(value)))
        end

        private

        def canonicalize(value)
          case value
          when Hash then value.map { |k, v| [k.to_s, canonicalize(v)] }.sort_by(&:first).to_h
          when Array then value.map { |v| canonicalize(v) }
          when Symbol then value.to_s
          else value
          end
        end
      end
    end
  end
end
