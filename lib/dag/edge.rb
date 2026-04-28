# frozen_string_literal: true

module DAG
  # First-class directed edge in the DAG. Frozen `Data` value carrying
  # `from`, `to`, and a JSON-safe metadata hash.
  # @api public
  Edge = Data.define(:from, :to, :metadata) do
    def initialize(from:, to:, metadata: {})
      super(from: from.to_sym, to: to.to_sym, metadata: DAG.frozen_copy(metadata))
    end

    # @return [Integer] convention: `metadata[:weight]` (default `1`)
    def weight = metadata.fetch(:weight, 1)

    # @return [String]
    def inspect
      metadata.empty? ? "Edge(#{from} -> #{to})" : "Edge(#{from} -> #{to}, #{metadata})"
    end
    alias_method :to_s, :inspect
  end
end
