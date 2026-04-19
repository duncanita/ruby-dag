# frozen_string_literal: true

module DAG
  # Describes the impact of a subtree replacement on a graph.
  #
  # Computed by Graph#subtree_replacement_impact before applying the mutation.
  #
  #   impact = graph.subtree_replacement_impact(:deploy, new_subgraph)
  #   impact.affected_nodes  # => [:notify, :rollback]  — downstream nodes
  #   impact.stale_nodes    # => [:notify]              — also have file outputs
  #   impact.is_safe        # => false
  SubtreeImpact = Data.define(:affected_nodes, :stale_nodes, :boundary_node,
                              :replacement_size, :is_safe)
end
