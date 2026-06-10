# frozen_string_literal: true

module DAG
  # Indifferent-key fetch helpers for deserializing JSON-safe snapshots.
  # `to_h` projections in this library use Symbol keys, but a round-trip
  # through a serializer turns them into Strings; `from_h` constructors
  # accept both spellings through these helpers.
  # @api private
  module Snapshot
    module_function

    # @param hash [Hash]
    # @param key [Symbol]
    # @param default [Object]
    # @return [Object]
    def fetch(hash, key, default = nil)
      hash.fetch(key) { hash.fetch(key.to_s, default) }
    end

    # @param hash [Hash]
    # @param key [Symbol]
    # @return [Object]
    # @raise [KeyError] when neither spelling of `key` is present
    def fetch!(hash, key)
      hash.fetch(key) do
        hash.fetch(key.to_s) { raise KeyError, "missing snapshot key: #{key}" }
      end
    end
  end
end
