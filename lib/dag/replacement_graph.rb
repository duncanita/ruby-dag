# frozen_string_literal: true

module DAG
  ReplacementGraph = Data.define(:graph, :entry_node_ids, :exit_node_ids) do
    class << self
      remove_method :[]

      def [](graph:, entry_node_ids:, exit_node_ids:)
        raise ArgumentError, "entry_node_ids cannot be empty" if entry_node_ids.empty?
        raise ArgumentError, "exit_node_ids cannot be empty" if exit_node_ids.empty?

        new(
          graph: graph,
          entry_node_ids: DAG.deep_freeze(entry_node_ids.dup),
          exit_node_ids: DAG.deep_freeze(exit_node_ids.dup)
        )
      end
    end

    def initialize(graph:, entry_node_ids:, exit_node_ids:)
      super(
        graph: graph,
        entry_node_ids: DAG.deep_freeze(DAG.deep_dup(entry_node_ids)),
        exit_node_ids: DAG.deep_freeze(DAG.deep_dup(exit_node_ids))
      )
    end
  end
end
