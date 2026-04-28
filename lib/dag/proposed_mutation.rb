# frozen_string_literal: true

module DAG
  # Proposal a step emits to ask the application to mutate the workflow
  # structurally. `kind` is one of {ProposedMutation::KINDS}; for
  # `:replace_subtree`, `replacement_graph` is required.
  # @api public
  ProposedMutation = Data.define(
    :kind,
    :target_node_id,
    :replacement_graph,
    :rationale,
    :confidence,
    :metadata
  ) do
    class << self
      remove_method :[]

      # Build a ProposedMutation with optional defaults.
      # @return [ProposedMutation]
      def [](kind:, target_node_id:, replacement_graph: nil, rationale: nil, confidence: 1.0, metadata: {})
        new(
          kind: kind,
          target_node_id: target_node_id,
          replacement_graph: replacement_graph,
          rationale: rationale,
          confidence: confidence,
          metadata: metadata
        )
      end
    end

    def initialize(kind:, target_node_id:, replacement_graph: nil, rationale: nil, confidence: 1.0, metadata: {})
      raise ArgumentError, "invalid mutation kind: #{kind.inspect}" unless DAG::ProposedMutation::KINDS.include?(kind)
      if kind == :replace_subtree && !replacement_graph.is_a?(DAG::ReplacementGraph)
        raise ArgumentError, "replace_subtree requires replacement_graph"
      end
      if kind == :invalidate && !replacement_graph.nil?
        raise ArgumentError, "invalidate does not accept replacement_graph"
      end

      DAG.json_safe!(rationale, "$root.rationale")
      DAG.json_safe!(confidence, "$root.confidence")
      DAG.json_safe!(metadata, "$root.metadata")

      super(
        kind: kind,
        target_node_id: target_node_id,
        replacement_graph: replacement_graph,
        rationale: DAG.deep_freeze(DAG.deep_dup(rationale)),
        confidence: confidence,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end

  # Closed set of mutation kinds.
  ProposedMutation::KINDS = %i[replace_subtree invalidate].freeze
end
