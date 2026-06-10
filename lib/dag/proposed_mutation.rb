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
      DAG::Validation.node_id!(target_node_id)
      DAG::Validation.member!(
        kind,
        DAG::ProposedMutation::KINDS,
        "kind",
        message: "invalid mutation kind: #{kind.inspect}"
      )
      if kind == :replace_subtree
        DAG::Validation.instance!(
          replacement_graph,
          DAG::ReplacementGraph,
          "replacement_graph",
          message: "replace_subtree requires replacement_graph"
        )
      end
      if kind == :invalidate && !replacement_graph.nil?
        raise ArgumentError, "invalidate does not accept replacement_graph"
      end

      DAG.json_safe!(rationale, "$root.rationale")
      DAG.json_safe!(confidence, "$root.confidence")
      DAG.json_safe!(metadata, "$root.metadata")

      super(
        kind: kind,
        target_node_id: target_node_id.to_sym,
        replacement_graph: replacement_graph,
        rationale: DAG.frozen_copy(rationale),
        confidence: confidence,
        metadata: DAG.frozen_copy(metadata)
      )
    end

    # Full-fidelity JSON-safe projection; round-trips via
    # {ProposedMutation.from_h}.
    # @return [Hash]
    def to_h
      {
        kind: kind,
        target_node_id: target_node_id,
        replacement_graph: replacement_graph&.to_h,
        rationale: rationale,
        confidence: confidence,
        metadata: metadata
      }
    end

    # Rebuild a ProposedMutation from a {#to_h} projection (Symbol or
    # String keys).
    # @param hash [Hash]
    # @return [ProposedMutation]
    def self.from_h(hash)
      DAG::Validation.hash!(hash, "proposed_mutation hash")
      replacement = DAG::Snapshot.fetch(hash, :replacement_graph)
      new(
        kind: DAG::Snapshot.fetch!(hash, :kind).to_sym,
        target_node_id: DAG::Snapshot.fetch!(hash, :target_node_id),
        replacement_graph: replacement && DAG::ReplacementGraph.from_h(replacement),
        rationale: DAG::Snapshot.fetch(hash, :rationale),
        confidence: DAG::Snapshot.fetch(hash, :confidence, 1.0),
        metadata: DAG::Snapshot.fetch(hash, :metadata, {})
      )
    end
  end

  # Closed set of mutation kinds.
  ProposedMutation::KINDS = %i[replace_subtree invalidate].freeze
end
