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
      DAG::Validation.member!(
        durability,
        DAG::RuntimeProfile::DURABILITY,
        "durability",
        message: "invalid durability"
      )
      DAG::Validation.positive_integer!(max_attempts_per_node, "max_attempts_per_node")
      DAG::Validation.nonnegative_integer!(max_workflow_retries, "max_workflow_retries")

      DAG.json_safe!(metadata, "$root.metadata")

      super(
        durability: durability,
        max_attempts_per_node: max_attempts_per_node,
        max_workflow_retries: max_workflow_retries,
        event_bus_kind: event_bus_kind,
        metadata: DAG.frozen_copy(metadata)
      )
    end
  end

  # Closed set of durability hints.
  RuntimeProfile::DURABILITY = %i[ephemeral durable].freeze
end
