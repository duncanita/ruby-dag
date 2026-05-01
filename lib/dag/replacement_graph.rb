# frozen_string_literal: true

module DAG
  # Structural replacement graph used by `:replace_subtree` mutations.
  # Carries graph shape plus explicit entry and exit node ids; entry/exit
  # are not inferred from roots/leaves.
  # @api public
  ReplacementGraph = Data.define(:graph, :entry_node_ids, :exit_node_ids) do
    class << self
      remove_method :[]

      # @param graph [DAG::Graph]
      # @param entry_node_ids [Array<Symbol, String>] non-empty
      # @param exit_node_ids [Array<Symbol, String>] non-empty
      # @return [ReplacementGraph]
      def [](graph:, entry_node_ids:, exit_node_ids:)
        new(graph: graph, entry_node_ids: entry_node_ids, exit_node_ids: exit_node_ids)
      end
    end

    def initialize(graph:, entry_node_ids:, exit_node_ids:)
      DAG::Validation.instance!(
        graph,
        DAG::Graph,
        "graph",
        message: "graph must be a DAG::Graph"
      )
      validate_node_ids_shape!(entry_node_ids, "entry_node_ids")
      validate_node_ids_shape!(exit_node_ids, "exit_node_ids")
      raise ArgumentError, "entry_node_ids cannot be empty" if entry_node_ids.empty?
      raise ArgumentError, "exit_node_ids cannot be empty" if exit_node_ids.empty?

      frozen_graph = graph.frozen? ? graph : graph.dup.freeze
      validate_membership!(frozen_graph, entry_node_ids, "entry")
      validate_membership!(frozen_graph, exit_node_ids, "exit")

      super(
        graph: frozen_graph,
        entry_node_ids: DAG.frozen_copy(entry_node_ids),
        exit_node_ids: DAG.frozen_copy(exit_node_ids)
      )
    end

    private

    def validate_node_ids_shape!(ids, label)
      DAG::Validation.array!(ids, label)

      ids.each do |id|
        DAG::Validation.string_or_symbol!(
          id,
          "#{label} entry",
          message: "#{label} entries must be Symbol or String, got #{id.class}: #{id.inspect}"
        )
      end
    end

    def validate_membership!(graph, ids, kind)
      ids.each do |id|
        raise ArgumentError, "#{kind} node not in graph: #{id}" unless graph.node?(id)
      end
    end
  end
end
