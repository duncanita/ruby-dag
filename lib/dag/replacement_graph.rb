# frozen_string_literal: true

module DAG
  ReplacementGraph = Data.define(:graph, :entry_node_ids, :exit_node_ids) do
    class << self
      remove_method :[]

      def [](graph:, entry_node_ids:, exit_node_ids:)
        new(graph: graph, entry_node_ids: entry_node_ids, exit_node_ids: exit_node_ids)
      end
    end

    def initialize(graph:, entry_node_ids:, exit_node_ids:)
      raise ArgumentError, "graph must be a DAG::Graph" unless graph.is_a?(DAG::Graph)
      validate_node_ids_shape!(entry_node_ids, "entry_node_ids")
      validate_node_ids_shape!(exit_node_ids, "exit_node_ids")
      raise ArgumentError, "entry_node_ids cannot be empty" if entry_node_ids.empty?
      raise ArgumentError, "exit_node_ids cannot be empty" if exit_node_ids.empty?

      frozen_graph = graph.frozen? ? graph : graph.dup.freeze
      validate_membership!(frozen_graph, entry_node_ids, "entry")
      validate_membership!(frozen_graph, exit_node_ids, "exit")

      super(
        graph: frozen_graph,
        entry_node_ids: DAG.deep_freeze(DAG.deep_dup(entry_node_ids)),
        exit_node_ids: DAG.deep_freeze(DAG.deep_dup(exit_node_ids))
      )
    end

    private

    def validate_node_ids_shape!(ids, label)
      raise ArgumentError, "#{label} must be an Array" unless ids.is_a?(Array)

      ids.each do |id|
        next if id.is_a?(Symbol) || id.is_a?(String)

        raise ArgumentError, "#{label} entries must be Symbol or String, got #{id.class}: #{id.inspect}"
      end
    end

    def validate_membership!(graph, ids, kind)
      ids.each do |id|
        raise ArgumentError, "#{kind} node not in graph: #{id}" unless graph.node?(id)
      end
    end
  end
end
