# frozen_string_literal: true

module DAG
  # Pure directed acyclic graph. Nodes are symbols, edges are first-class.
  # Enforces acyclicity on every add_edge call.
  #
  #   graph = DAG::Graph.new
  #     .add_node(:fetch)
  #     .add_node(:parse)
  #     .add_edge(:fetch, :parse)
  #
  #   graph.topological_sort  # => [[:fetch], [:parse]]
  #   graph.descendants(:fetch) # => Set[:parse]

  Edge = Data.define(:from, :to) do
    def initialize(from:, to:)
      super(from: from.to_sym, to: to.to_sym)
    end

    def inspect = "Edge(#{from} → #{to})"
    alias_method :to_s, :inspect
  end

  class Graph
    attr_reader :nodes, :edges

    def initialize
      @nodes = Set.new
      @adjacency = Hash.new { |h, k| h[k] = Set.new }   # from → Set[to]
      @reverse = Hash.new { |h, k| h[k] = Set.new }      # to → Set[from]
      @edges = Set.new
    end

    # --- Mutation ---

    def add_node(name)
      sym = name.to_sym
      raise ArgumentError, "Duplicate node: #{sym}" if @nodes.include?(sym)

      @nodes << sym
      self
    end

    def add_edge(from, to)
      from_sym = from.to_sym
      to_sym = to.to_sym

      validate_edge_nodes!(from_sym, to_sym)
      raise ArgumentError, "Self-referencing edge: #{from_sym}" if from_sym == to_sym

      edge = Edge.new(from: from_sym, to: to_sym)
      return self if @edges.include?(edge)

      raise CycleError, "Edge #{from_sym} → #{to_sym} would create a cycle" if would_create_cycle?(from_sym, to_sym)

      @adjacency[from_sym] << to_sym
      @reverse[to_sym] << from_sym
      @edges << edge
      self
    end

    # --- Queries ---

    def size = @nodes.size
    def empty? = @nodes.empty?
    def node?(name) = @nodes.include?(name.to_sym)
    def edge?(from, to) = @edges.include?(Edge.new(from: from, to: to))

    def successors(name) = @adjacency[name.to_sym].dup
    def predecessors(name) = @reverse[name.to_sym].dup

    def roots = @nodes.select { |n| @reverse[n].empty? }
    def leaves = @nodes.select { |n| @adjacency[n].empty? }

    def ancestors(name)
      walk(:predecessors, name.to_sym)
    end

    def descendants(name)
      walk(:successors, name.to_sym)
    end

    # Kahn's algorithm: topological sort into parallel layers.
    # Returns array of arrays — nodes in each layer can run concurrently.
    def topological_sort
      in_degree = @nodes.to_h { |n| [n, @reverse[n].size] }
      remaining = @nodes.dup
      layers = []

      until remaining.empty?
        ready = remaining.select { |n| in_degree[n] == 0 }
        raise CycleError, "Graph contains a cycle" if ready.empty?

        layers << ready.sort
        ready.each do |n|
          remaining.delete(n)
          @adjacency[n].each { |succ| in_degree[succ] -= 1 }
        end
      end

      layers
    end

    # Returns a new Graph containing only the specified nodes and edges between them.
    def subgraph(node_names)
      keep = node_names.map(&:to_sym).to_set
      raise ArgumentError, "Unknown nodes: #{(keep - @nodes).to_a}" unless keep.subset?(@nodes)

      keep.each_with_object(Graph.new) do |n, g|
        g.add_node(n)
      end.then do |g|
        @edges.each do |edge|
          g.add_edge(edge.from, edge.to) if keep.include?(edge.from) && keep.include?(edge.to)
        end
        g
      end
    end

    def inspect
      "#<DAG::Graph nodes=#{@nodes.to_a} edges=#{@edges.size}>"
    end
    alias_method :to_s, :inspect

    private

    def walk(direction, start)
      visited = Set.new
      stack = send(direction, start).to_a

      until stack.empty?
        current = stack.pop
        next if visited.include?(current)

        visited << current
        stack.concat(send(direction, current).to_a)
      end

      visited
    end

    def validate_edge_nodes!(from, to)
      raise ArgumentError, "Unknown node: #{from}" unless @nodes.include?(from)
      raise ArgumentError, "Unknown node: #{to}" unless @nodes.include?(to)
    end

    # Would adding from→to create a cycle? True if `to` can already reach `from`.
    def would_create_cycle?(from, to)
      visited = Set.new
      stack = [to]

      until stack.empty?
        current = stack.pop
        next if visited.include?(current)

        return true if current == from

        visited << current
        @adjacency[current].each { |succ| stack << succ }
      end

      false
    end
  end
end
