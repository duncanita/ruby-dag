# frozen_string_literal: true

module DAG
  # Describes the outcome of a graph mutation operation.
  #
  #   result = graph.replace_subtree(:old_node, replacement_subgraph)
  #   result.success?        # => true
  #   result.added_nodes     # => [:new_a, :new_b]
  #   result.removed_nodes   # => [:old_a, :old_b]
  #   result.stale_nodes     # => [:consumer]  # downstream nodes now reading stale artifacts
  MutationResult = Data.define(:success, :new_graph, :added_nodes, :removed_nodes,
                               :stale_nodes, :error) do
    # Returns true when the mutation was valid and the new graph is usable.
    def success? = success

    def self.failure(error)
      new(success: false, new_graph: nil, added_nodes: [], removed_nodes: [],
          stale_nodes: [], error: error)
    end

    def self.success(new_graph:, added_nodes:, removed_nodes:, stale_nodes: [])
      new(success: true, new_graph: new_graph, added_nodes: added_nodes,
          removed_nodes: removed_nodes, stale_nodes: stale_nodes, error: nil)
    end
  end
end
