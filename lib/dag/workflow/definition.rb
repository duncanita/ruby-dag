# frozen_string_literal: true

module DAG
  # Workflow domain: top-level immutable workflow definition and the
  # tagged types it composes with.
  # @api public
  module Workflow
    # Immutable, chainable workflow definition. Each `add_node` / `add_edge`
    # returns a new frozen Definition with a fresh frozen Graph and
    # step-type mapping. R3's mutation service returns Definitions with
    # incremented revisions; R1 always uses revision 1.
    # @api public
    class Definition
      # @return [DAG::Graph]
      attr_reader :graph
      # @return [Integer]
      attr_reader :revision

      # @param graph [DAG::Graph] frozen (or freezable) graph
      # @param step_types [Hash{Symbol => Hash}] node id => {type:, config:}
      # @param revision [Integer] positive
      def initialize(graph: DAG::Graph.new.freeze, step_types: {}, revision: 1)
        raise ArgumentError, "revision must be a positive Integer" unless revision.is_a?(Integer) && revision.positive?

        @graph = graph.frozen? ? graph : graph.dup.freeze
        @step_types = DAG.deep_freeze(DAG.deep_dup(step_types))
        @revision = revision
        @hash = to_h.hash
        freeze
      end

      # Return a new frozen Definition with `id` added as `type`.
      # @param id [Symbol, String]
      # @param type [Symbol] registered step-type name
      # @param config [Hash] JSON-safe step config
      # @return [Definition]
      # @raise [DAG::DuplicateNodeError] when `id` already exists
      def add_node(id, type:, config: {})
        sym = id.to_sym
        raise ArgumentError, "type must be a Symbol" unless type.is_a?(Symbol)

        new_graph = @graph.with_node(sym)
        new_step_types = @step_types.merge(sym => {type: type, config: DAG.deep_freeze(DAG.deep_dup(config))})
        Definition.new(graph: new_graph, step_types: new_step_types, revision: @revision)
      end

      # Return a new frozen Definition with the edge added.
      # @param from [Symbol, String]
      # @param to [Symbol, String]
      # @param metadata [Hash] JSON-safe edge metadata
      # @return [Definition]
      # @raise [DAG::CycleError] when adding the edge would create a cycle
      def add_edge(from, to, **metadata)
        new_graph = @graph.with_edge(from, to, **metadata)
        Definition.new(graph: new_graph, step_types: @step_types, revision: @revision)
      end

      # Return the same definition with a different `revision` value.
      # @param new_revision [Integer]
      # @return [Definition]
      def with_revision(new_revision)
        Definition.new(graph: @graph, step_types: @step_types, revision: new_revision)
      end

      # @param id [Symbol, String]
      # @return [Hash] {type:, config:}
      # @raise [DAG::UnknownNodeError]
      def step_type_for(id)
        sym = id.to_sym
        raise UnknownNodeError, "Unknown node: #{sym}" unless @step_types.key?(sym)
        @step_types.fetch(sym)
      end

      # @return [Boolean]
      def has_node?(id) = @graph.node?(id)

      # @return [Set<Symbol>]
      def nodes = @graph.nodes

      # @return [Array<Symbol>] deterministic Kahn order
      def topological_order = @graph.topological_order

      # @return [Set<Symbol>]
      def predecessors(id) = @graph.predecessors(id)

      # @return [Set<Symbol>]
      def successors(id) = @graph.successors(id)

      # Iterate node ids.
      def each_node(&block) = @graph.each_node(&block)

      # Iterate edges.
      def each_edge(&block) = @graph.each_edge(&block)

      # Iterate the predecessors of `id`.
      def each_predecessor(id, &block) = @graph.each_predecessor(id, &block)

      # Iterate the successors of `id`.
      def each_successor(id, &block) = @graph.each_successor(id, &block)

      # @return [Set<Symbol>] all reachable descendants
      def descendants_of(id, **opts) = @graph.descendants_of(id, **opts)

      # @return [Set<Symbol>] descendants reached only via `id`
      def exclusive_descendants_of(id, **opts) = @graph.exclusive_descendants_of(id, **opts)

      # @return [Set<Symbol>] descendants also reachable from siblings
      def shared_descendants_of(id) = @graph.shared_descendants_of(id)

      # Canonical, ASCII-sorted hash representation suitable for fingerprinting.
      # @return [Hash]
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

      # @param via [Object] adapter implementing `Ports::Fingerprint`
      # @return [String] hex digest
      def fingerprint(via:)
        via.compute(to_h)
      end

      # @return [Boolean]
      def ==(other)
        return true if equal?(other)
        return false unless other.is_a?(Definition)
        return false unless hash == other.hash

        to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash = @hash

      # @return [String]
      def inspect = "#<DAG::Workflow::Definition revision=#{@revision} nodes=#{@graph.node_count} edges=#{@graph.edge_count}>"
      alias_method :to_s, :inspect
    end
  end
end
