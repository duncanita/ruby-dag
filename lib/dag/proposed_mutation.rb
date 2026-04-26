# frozen_string_literal: true

module DAG
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

      def [](kind:, target_node_id:, replacement_graph: nil, rationale: nil, confidence: 1.0, metadata: {})
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

        new(
          kind: kind,
          target_node_id: target_node_id,
          replacement_graph: replacement_graph,
          rationale: DAG.deep_freeze(DAG.deep_dup(rationale)),
          confidence: confidence,
          metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
        )
      end
    end

    def initialize(kind:, target_node_id:, replacement_graph: nil, rationale: nil, confidence: 1.0, metadata: {})
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

  ProposedMutation::KINDS = %i[replace_subtree invalidate].freeze
end
