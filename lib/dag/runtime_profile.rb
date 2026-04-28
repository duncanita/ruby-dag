# frozen_string_literal: true

module DAG
  # Per-workflow runtime profile. Frozen Data carrying the durability hint,
  # the per-node attempt budget, and the workflow-level retry budget.
  # @api public
  RuntimeProfile = Data.define(:durability, :max_attempts_per_node, :max_workflow_retries, :event_bus_kind, :metadata) do
    class << self
      remove_method :[]

      # @param durability [Symbol] one of {DURABILITY}
      # @param max_attempts_per_node [Integer] positive
      # @param max_workflow_retries [Integer] non-negative
      # @param event_bus_kind [Symbol]
      # @param metadata [Hash] JSON-safe
      # @return [RuntimeProfile]
      def [](durability:, max_attempts_per_node:, max_workflow_retries:, event_bus_kind:, metadata: {})
        new(
          durability: durability,
          max_attempts_per_node: max_attempts_per_node,
          max_workflow_retries: max_workflow_retries,
          event_bus_kind: event_bus_kind,
          metadata: metadata
        )
      end
    end

    # Sensible defaults for in-memory examples and tests.
    # @return [RuntimeProfile]
    def self.default
      self[
        durability: :ephemeral,
        max_attempts_per_node: 3,
        max_workflow_retries: 0,
        event_bus_kind: :null,
        metadata: {}
      ]
    end

    def initialize(durability:, max_attempts_per_node:, max_workflow_retries:, event_bus_kind:, metadata: {})
      raise ArgumentError, "invalid durability" unless DAG::RuntimeProfile::DURABILITY.include?(durability)
      unless max_attempts_per_node.is_a?(Integer) && max_attempts_per_node.positive?
        raise ArgumentError, "max_attempts_per_node must be a positive Integer"
      end
      unless max_workflow_retries.is_a?(Integer) && !max_workflow_retries.negative?
        raise ArgumentError, "max_workflow_retries must be a non-negative Integer"
      end

      DAG.json_safe!(metadata, "$root.metadata")

      super(
        durability: durability,
        max_attempts_per_node: max_attempts_per_node,
        max_workflow_retries: max_workflow_retries,
        event_bus_kind: event_bus_kind,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end

  # Closed set of durability hints.
  RuntimeProfile::DURABILITY = %i[ephemeral durable].freeze
end
