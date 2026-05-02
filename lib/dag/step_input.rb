# frozen_string_literal: true

module DAG
  # Carrier the Runner passes to each step's `#call`. `context` is a
  # deep-frozen `ExecutionContext`; `metadata` carries the JSON-safe runtime
  # data used by {#runtime_snapshot}, including the node-scoped effect snapshot
  # under `:effects`.
  # @api public
  StepInput = Data.define(:context, :node_id, :attempt_number, :metadata) do
    class << self
      remove_method :[]

      # @param context [DAG::ExecutionContext]
      # @param node_id [Symbol]
      # @param attempt_number [Integer]
      # @param metadata [Hash]
      # @return [StepInput]
      def [](context:, node_id:, attempt_number: 1, metadata: {})
        new(
          context: context,
          node_id: node_id,
          attempt_number: attempt_number,
          metadata: metadata
        )
      end
    end

    def initialize(context:, node_id:, attempt_number: 1, metadata: {})
      DAG.json_safe!(metadata, "$root.metadata")

      super(
        context: DAG.frozen_copy(context),
        node_id: node_id,
        attempt_number: attempt_number,
        metadata: DAG.frozen_copy(metadata)
      )
    end

    # @return [DAG::RuntimeSnapshot] public runtime boundary for this attempt
    def runtime_snapshot
      DAG::RuntimeSnapshot[
        workflow_id: metadata.fetch(:workflow_id),
        revision: metadata.fetch(:revision),
        node_id: node_id,
        attempt_id: metadata.fetch(:attempt_id),
        attempt_number: attempt_number,
        predecessors: metadata.fetch(:predecessors, {}),
        effects: metadata.fetch(:effects, {}),
        metadata: metadata.fetch(:runtime_metadata, {})
      ]
    end
  end
end
