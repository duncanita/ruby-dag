# frozen_string_literal: true

module DAG
  module Workflow
    # Immutable, chainable workflow definition. Each `add_node` / `add_edge`
    # returns a new frozen Definition with a fresh frozen Graph and
    # step-type mapping. R3's mutation service will return Definitions with
    # incremented revisions; R1 always uses revision 1.
    class Definition
      attr_reader :graph, :revision

      def initialize(graph: DAG::Graph.new.freeze, step_types: {}, revision: 1)
        raise ArgumentError, "revision must be a positive Integer" unless revision.is_a?(Integer) && revision.positive?

        @graph = graph.frozen? ? graph : graph.dup.freeze
        @step_types = DAG.deep_freeze(DAG.deep_dup(step_types))
        @revision = revision
        freeze
      end

      def add_node(id, type:, config: {})
        sym = id.to_sym
        raise ArgumentError, "type must be a Symbol" unless type.is_a?(Symbol)

        new_graph = @graph.with_node(sym)
        new_step_types = @step_types.merge(sym => {type: type, config: DAG.deep_freeze(DAG.deep_dup(config))})
        Definition.new(graph: new_graph, step_types: new_step_types, revision: @revision)
      end

      def add_edge(from, to, **metadata)
        new_graph = @graph.with_edge(from, to, **metadata)
        Definition.new(graph: new_graph, step_types: @step_types, revision: @revision)
      end

      def with_revision(new_revision)
        Definition.new(graph: @graph, step_types: @step_types, revision: new_revision)
      end

      def step_type_for(id)
        sym = id.to_sym
        raise UnknownNodeError, "Unknown node: #{sym}" unless @step_types.key?(sym)
        @step_types.fetch(sym)
      end

      def has_node?(id) = @graph.node?(id)
      def nodes = @graph.nodes
      def topological_order = @graph.topological_order
      def predecessors(id) = @graph.predecessors(id)
      def successors(id) = @graph.successors(id)
      def each_node(&block) = @graph.each_node(&block)
      def each_edge(&block) = @graph.each_edge(&block)
      def descendants_of(id, **opts) = @graph.descendants_of(id, **opts)
      def exclusive_descendants_of(id, **opts) = @graph.exclusive_descendants_of(id, **opts)
      def shared_descendants_of(id) = @graph.shared_descendants_of(id)

      def to_h
        graph_hash = @graph.to_h
        {
          revision: @revision,
          nodes: graph_hash[:nodes].map { |id|
            entry = @step_types.fetch(id)
            {id: id, type: entry[:type], config: entry[:config]}
          },
          edges: graph_hash[:edges]
        }
      end

      def fingerprint(via:)
        via.compute(to_h)
      end

      def ==(other)
        other.is_a?(Definition) && to_h == other.to_h
      end
      alias_method :eql?, :==

      def hash = to_h.hash

      def inspect = "#<DAG::Workflow::Definition revision=#{@revision} nodes=#{@graph.node_count} edges=#{@graph.edge_count}>"
      alias_method :to_s, :inspect
    end
  end
end
