# frozen_string_literal: true

module DAG
  # First-class directed edge in the DAG.
  Edge = Data.define(:from, :to) do
    def initialize(from:, to:)
      super(from: from.to_sym, to: to.to_sym)
    end

    def inspect = "Edge(#{from} → #{to})"
    alias_method :to_s, :inspect
  end
end
