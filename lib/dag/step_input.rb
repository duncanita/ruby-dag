# frozen_string_literal: true

module DAG
  # Carrier the Runner passes to each step's `#call`. `context` is a
  # deep-frozen `ExecutionContext`; `metadata` carries `workflow_id` and
  # `revision`.
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
        context: DAG.deep_freeze(DAG.deep_dup(context)),
        node_id: node_id,
        attempt_number: attempt_number,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end
end
