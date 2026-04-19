# frozen_string_literal: true

module DAG
  # Utilities for applying graph mutations to a running system.
  #
  # {apply_subtree_replacement_impact} deletes output artifacts produced by
  # stale nodes so that a subsequent DAG run re-executes them cleanly.
  #
  #   result = graph.replace_subtree(:build, new_build_graph)
  #   apply_subtree_replacement_impact(result, artifact_paths)
  #   DAG::Runner.new(result.new_graph).call
  #
  # This is only needed when your workflow uses +file_write+ nodes to
  # persist outputs between separate invocations of the DAG. If you always
  # run from a clean state, this step is unnecessary.
  module MutationUtils
    # Remove artifacts produced by stale nodes so they will be regenerated.
    #
    # +mutation_result+:: a {MutationResult} from {#replace_subtree}
    # +artifact_registry+:: a hash mapping node names to their output file paths
    #
    # Returns a list of files that were deleted, or an empty array if
    # nothing needed cleaning.
    #
    # Does not raise on missing files — treats them as already absent.
    #
    #   deleted = apply_subtree_replacement_impact(result, {
    #     notify: "/tmp/notify.txt",
    #     rollback: "/tmp/rollback.json"
    #   })
    #
    def self.apply_subtree_replacement_impact(mutation_result, artifact_registry)
      return [] unless mutation_result.success?
      return [] if mutation_result.stale_nodes.empty?

      deleted = []
      mutation_result.stale_nodes.each do |node_name|
        path = artifact_registry[node_name.to_sym]
        next unless path

        path_str = path.to_s
        if File.exist?(path_str)
          File.delete(path_str)
          deleted << path_str
        end
      end
      deleted
    end
  end
end
