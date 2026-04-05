# frozen_string_literal: true

module DAG
  # Pure directed acyclic graph. Nodes are symbols, edges are first-class.
  # Enforces acyclicity on every add_edge call.
  # Supports freeze for immutability after construction.
  #
  #   graph = DAG::Graph.new
  #     .add_node(:fetch)
  #     .add_node(:parse)
  #     .add_edge(:fetch, :parse)
  #
  #   graph.topological_layers # => [[:fetch], [:parse]]
  #   graph.topological_sort   # => [:fetch, :parse]
  #   graph.descendants(:fetch) # => Set[:parse]

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
      check_frozen!
      sym = name.to_sym
      raise ArgumentError, "Duplicate node: #{sym}" if @nodes.include?(sym)

      @nodes << sym
      self
    end

    def add_edge(from, to)
      check_frozen!
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

    def remove_node(name)
      check_frozen!
      sym = name.to_sym
      raise ArgumentError, "Unknown node: #{sym}" unless @nodes.include?(sym)

      fetch_set(@adjacency, sym).dup.each { |to| remove_edge_internal(sym, to) }
      fetch_set(@reverse, sym).dup.each { |from| remove_edge_internal(from, sym) }

      @adjacency.delete(sym)
      @reverse.delete(sym)
      @nodes.delete(sym)
      self
    end

    def remove_edge(from, to)
      check_frozen!
      from_sym = from.to_sym
      to_sym = to.to_sym
      raise ArgumentError, "Unknown edge: #{from_sym} → #{to_sym}" unless @edges.include?(Edge.new(from: from_sym, to: to_sym))

      remove_edge_internal(from_sym, to_sym)
      self
    end

    # --- Immutable builders ---

    def with_node(name)
      dup.add_node(name).freeze
    end

    def with_edge(from, to)
      dup.add_edge(from, to).freeze
    end

    def without_node(name)
      dup.tap { |g| g.remove_node(name) }.freeze
    end

    def without_edge(from, to)
      dup.tap { |g| g.remove_edge(from, to) }.freeze
    end

    # --- Freezing ---

    def freeze
      @nodes.freeze
      @edges.freeze
      @adjacency.each_value(&:freeze)
      @adjacency.freeze
      @reverse.each_value(&:freeze)
      @reverse.freeze
      super
    end

    # --- Scalar queries ---

    def size = @nodes.size
    def empty? = @nodes.empty?
    def node?(name) = @nodes.include?(name.to_sym)
    def edge?(from, to) = @edges.include?(Edge.new(from: from, to: to))

    def indegree(name) = fetch_set(@reverse, name.to_sym).size
    def outdegree(name) = fetch_set(@adjacency, name.to_sym).size

    # --- Neighbor queries ---

    def successors(name) = fetch_set(@adjacency, name.to_sym).dup
    def predecessors(name) = fetch_set(@reverse, name.to_sym).dup

    def roots = @nodes.select { |n| fetch_set(@reverse, n).empty? }
    def leaves = @nodes.select { |n| fetch_set(@adjacency, n).empty? }

    # --- Transitive queries ---

    def ancestors(name)
      walk(@reverse, name.to_sym)
    end

    def descendants(name)
      walk(@adjacency, name.to_sym)
    end

    # Is there a directed path from `from` to `to`?
    def path?(from, to)
      from_sym = from.to_sym
      to_sym = to.to_sym
      return false unless @nodes.include?(from_sym) && @nodes.include?(to_sym)
      return true if from_sym == to_sym

      reachable?(from_sym, to_sym)
    end

    # --- Topological algorithms ---

    # Kahn's algorithm: topological sort into parallel layers.
    # Returns array of arrays — nodes in each layer can run concurrently.
    def topological_layers
      in_degree = @nodes.to_h { |n| [n, fetch_set(@reverse, n).size] }
      remaining = @nodes.dup
      layers = []

      until remaining.empty?
        ready = remaining.select { |n| in_degree[n] == 0 }
        raise CycleError, "Graph contains a cycle" if ready.empty?

        layers << ready.sort
        ready.each do |n|
          remaining.delete(n)
          fetch_set(@adjacency, n).each { |succ| in_degree[succ] -= 1 }
        end
      end

      layers
    end

    # Flat deterministic topological ordering.
    def topological_sort
      topological_layers.flatten
    end

    # --- Iteration ---

    def each_node(&block)
      return enum_for(:each_node) unless block
      @nodes.each(&block)
    end

    def each_edge(&block)
      return enum_for(:each_edge) unless block
      @edges.each(&block)
    end

    # --- Subgraph ---

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

    def to_h
      {
        nodes: @nodes.to_a.sort,
        edges: @edges.map { |e| {from: e.from, to: e.to} }
      }
    end

    def ==(other)
      other.is_a?(Graph) && @nodes == other.nodes && @edges == other.edges
    end
    alias_method :eql?, :==

    def hash
      [@nodes, @edges].hash
    end

    def inspect
      "#<DAG::Graph nodes=#{@nodes.to_a} edges=#{@edges.size}>"
    end
    alias_method :to_s, :inspect

    private

    def initialize_dup(orig)
      super
      @nodes = @nodes.dup
      @edges = @edges.dup
      @adjacency = deep_dup_hash_of_sets(@adjacency)
      @reverse = deep_dup_hash_of_sets(@reverse)
    end

    def deep_dup_hash_of_sets(hash)
      Hash.new { |h, k| h[k] = Set.new }.tap do |h|
        hash.each { |k, v| h[k] = v.dup }
      end
    end

    def check_frozen!
      raise FrozenError, "can't modify frozen #{self.class}" if frozen?
    end

    def remove_edge_internal(from, to)
      @adjacency[from]&.delete(to)
      @reverse[to]&.delete(from)
      @edges.delete(Edge.new(from: from, to: to))
    end

    # Safe hash lookup that doesn't trigger the default block on frozen hashes.
    def fetch_set(hash, key)
      hash.fetch(key) { Set.new }
    end

    def walk(adjacency_hash, start)
      visited = Set.new
      stack = fetch_set(adjacency_hash, start).to_a

      until stack.empty?
        current = stack.pop
        next if visited.include?(current)

        visited << current
        stack.concat(fetch_set(adjacency_hash, current).to_a)
      end

      visited
    end

    def validate_edge_nodes!(from, to)
      raise ArgumentError, "Unknown node: #{from}" unless @nodes.include?(from)
      raise ArgumentError, "Unknown node: #{to}" unless @nodes.include?(to)
    end

    def reachable?(from, to)
      visited = Set.new
      stack = fetch_set(@adjacency, from).to_a

      until stack.empty?
        current = stack.pop
        next if visited.include?(current)
        return true if current == to

        visited << current
        stack.concat(fetch_set(@adjacency, current).to_a)
      end

      false
    end

    # Would adding from→to create a cycle? True if `to` can already reach `from`.
    def would_create_cycle?(from, to)
      reachable?(to, from)
    end
  end
end
