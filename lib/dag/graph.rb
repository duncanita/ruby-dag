# frozen_string_literal: true

module DAG
  class Graph
    include Enumerable

    attr_reader :nodes

    def initialize
      @nodes = Set.new
      @adjacency = Hash.new { |h, k| h[k] = Set.new }   # from → Set[to]
      @reverse = Hash.new { |h, k| h[k] = Set.new }      # to → Set[from]
      @edge_metadata = {}                                  # [from, to] → Hash
    end

    # --- Mutation ---

    def add_node(name)
      check_frozen!
      sym = name.to_sym
      raise DuplicateNodeError, "Duplicate node: #{sym}" if @nodes.include?(sym)

      @nodes << sym
      self
    end

    def add_edge(from, to, **metadata)
      check_frozen!
      from_sym = from.to_sym
      to_sym = to.to_sym

      validate_edge_nodes!(from_sym, to_sym)
      raise ArgumentError, "Self-referencing edge: #{from_sym}" if from_sym == to_sym
      return self if fetch_set(@adjacency, from_sym).include?(to_sym)
      raise CycleError, "Edge #{from_sym} → #{to_sym} would create a cycle" if reachable?(to_sym, from_sym)

      @adjacency[from_sym] << to_sym
      @reverse[to_sym] << from_sym
      @edge_metadata[[from_sym, to_sym]] = metadata.freeze unless metadata.empty?
      self
    end

    def remove_node(name)
      check_frozen!
      sym = name.to_sym
      raise UnknownNodeError, "Unknown node: #{sym}" unless @nodes.include?(sym)

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
      raise UnknownNodeError, "Unknown edge: #{from_sym} → #{to_sym}" unless fetch_set(@adjacency, from_sym).include?(to_sym)

      remove_edge_internal(from_sym, to_sym)
      self
    end

    def replace_node(old_name, new_name)
      check_frozen!
      old_sym = old_name.to_sym
      new_sym = new_name.to_sym
      return self if old_sym == new_sym

      raise UnknownNodeError, "Unknown node: #{old_sym}" unless @nodes.include?(old_sym)
      raise DuplicateNodeError, "Duplicate node: #{new_sym}" if @nodes.include?(new_sym)

      incoming = fetch_set(@reverse, old_sym).map { |pred| [pred, edge_metadata(pred, old_sym)] }
      outgoing = fetch_set(@adjacency, old_sym).map { |succ| [succ, edge_metadata(old_sym, succ)] }

      remove_node(old_sym)
      add_node(new_sym)

      incoming.each { |pred, meta| add_edge(pred, new_sym, **meta) }
      outgoing.each { |succ, meta| add_edge(new_sym, succ, **meta) }

      self
    end

    # --- Immutable builders ---

    def with_node(name)
      dup.add_node(name).freeze
    end

    def with_edge(from, to, **metadata)
      dup.add_edge(from, to, **metadata).freeze
    end

    def without_node(name)
      dup.tap { |g| g.remove_node(name) }.freeze
    end

    def without_edge(from, to)
      dup.tap { |g| g.remove_edge(from, to) }.freeze
    end

    def with_node_replaced(old_name, new_name)
      dup.tap { |g| g.replace_node(old_name, new_name) }.freeze
    end

    # --- Freezing ---

    def freeze
      @nodes.freeze
      @adjacency.each_value(&:freeze)
      @adjacency.freeze
      @reverse.each_value(&:freeze)
      @reverse.freeze
      @edge_metadata.freeze
      @cached_layers = compute_topological_layers.freeze
      @cached_sort = @cached_layers.flatten.freeze
      @cached_roots = nodes_with_no(@reverse).freeze
      @cached_leaves = nodes_with_no(@adjacency).freeze
      @cached_edges = compute_edges.freeze
      super
    end

    # --- Scalar queries ---

    def size = @nodes.size
    def empty? = @nodes.empty?
    def node?(name) = @nodes.include?(name.to_sym)

    def edge?(from, to)
      fetch_set(@adjacency, from.to_sym).include?(to.to_sym)
    end

    def indegree(name) = fetch_set(@reverse, name.to_sym).size
    def outdegree(name) = fetch_set(@adjacency, name.to_sym).size

    # --- Edge objects ---

    def edges
      return @cached_edges if frozen?
      compute_edges
    end

    def incoming_edges(node)
      sym = node.to_sym
      fetch_set(@reverse, sym).map { |from| Edge.new(from: from, to: sym, metadata: edge_metadata(from, sym)) }
    end

    def edge_metadata(from, to)
      @edge_metadata.fetch([from.to_sym, to.to_sym], {})
    end

    # --- Neighbor queries ---

    def successors(name) = fetch_set(@adjacency, name.to_sym).dup
    def predecessors(name) = fetch_set(@reverse, name.to_sym).dup

    def roots = frozen? ? @cached_roots : nodes_with_no(@reverse)
    def leaves = frozen? ? @cached_leaves : nodes_with_no(@adjacency)

    # --- Transitive queries ---

    def ancestors(name) = walk(@reverse, name.to_sym)
    def descendants(name) = walk(@adjacency, name.to_sym)

    def path?(from, to)
      from_sym = from.to_sym
      to_sym = to.to_sym
      return false unless @nodes.include?(from_sym) && @nodes.include?(to_sym)
      return true if from_sym == to_sym
      reachable?(from_sym, to_sym)
    end

    # --- Topological algorithms ---

    def topological_layers
      return @cached_layers if frozen?
      compute_topological_layers
    end

    def topological_sort
      return @cached_sort if frozen?
      topological_layers.flatten
    end

    def shortest_path(from, to)
      weighted_path(from, to, Float::INFINITY) { |a, b| a < b }
    end

    def longest_path(from, to)
      weighted_path(from, to, -Float::INFINITY) { |a, b| a > b }
    end

    def critical_path
      return nil if empty?

      dist, pred = relax(roots, -Float::INFINITY) { |a, b| a > b }
      target = leaves.max_by { |l| dist[l] }
      {cost: dist[target], path: rebuild_path(pred, target)}
    end

    # --- Iteration ---

    def each(&block)
      return enum_for(:each) unless block
      @nodes.each(&block)
    end

    alias_method :each_node, :each

    def each_edge(&block)
      return enum_for(:each_edge) unless block
      edges.each(&block)
    end

    # --- Subgraph ---

    def subgraph(node_names)
      keep = node_names.map(&:to_sym).to_set
      raise ArgumentError, "Unknown nodes: #{(keep - @nodes).to_a}" unless keep.subset?(@nodes)

      keep.each_with_object(Graph.new) do |n, g|
        g.add_node(n)
      end.then do |g|
        keep.each do |from|
          fetch_set(@adjacency, from).each do |to|
            g.add_edge(from, to, **edge_metadata(from, to)) if keep.include?(to)
          end
        end
        g
      end
    end

    def to_dot(name: "dag")
      sorted = topological_sort
      lines = ["digraph #{name} {"]
      sorted.each { |n| lines << "  #{n};" }
      sorted.each do |from|
        fetch_set(@adjacency, from).sort.each do |to|
          meta = edge_metadata(from, to)
          if meta.empty?
            lines << "  #{from} -> #{to};"
          else
            label = meta.map { |k, v| "#{k}=#{v}" }.join(", ")
            lines << "  #{from} -> #{to} [label=\"#{label}\"];"
          end
        end
      end
      lines << "}"
      lines.join("\n")
    end

    def to_h
      {
        nodes: @nodes.to_a.sort,
        edges: edges.map { |e|
          h = {from: e.from, to: e.to}
          h[:metadata] = e.metadata unless e.metadata.empty?
          h
        }
      }
    end

    def ==(other)
      other.is_a?(Graph) && @nodes == other.nodes && edges == other.edges
    end
    alias_method :eql?, :==

    def hash
      [@nodes, edges].hash
    end

    def inspect
      "#<DAG::Graph nodes=#{@nodes.to_a} edges=#{edges.size}>"
    end
    alias_method :to_s, :inspect

    private

    def nodes_with_no(hash) = @nodes.select { |n| fetch_set(hash, n).empty? }

    def compute_edges
      @adjacency.each_with_object(Set.new) do |(from, tos), set|
        tos.each { |to| set << Edge.new(from: from, to: to, metadata: edge_metadata(from, to)) }
      end
    end

    def weighted_path(from, to, sentinel, &better)
      from_sym = from.to_sym
      to_sym = to.to_sym
      return nil unless @nodes.include?(from_sym) && @nodes.include?(to_sym)
      return {cost: 0, path: [from_sym]} if from_sym == to_sym

      dist, pred = relax(from_sym, sentinel, &better)
      return nil if dist[to_sym] == sentinel
      {cost: dist[to_sym], path: rebuild_path(pred, to_sym)}
    end

    # Single- or multi-source relaxation in topological order.
    # `sources` may be a Symbol or any Enumerable of Symbols. Each source
    # starts with cost 0; all other nodes start at `sentinel`.
    # `better` decides whether a candidate cost replaces the current one.
    # Returns [dist, pred].
    def relax(sources, sentinel, &better)
      dist = Hash.new(sentinel)
      Array(sources).each { |s| dist[s] = 0 }
      pred = {}

      topological_sort.each do |u|
        next if dist[u] == sentinel

        fetch_set(@adjacency, u).each do |v|
          candidate = dist[u] + edge_metadata(u, v).fetch(:weight, 1)
          if better.call(candidate, dist[v])
            dist[v] = candidate
            pred[v] = u
          end
        end
      end

      [dist, pred]
    end

    def rebuild_path(pred, target)
      path = [target]
      path << pred[path.last] while pred.key?(path.last)
      path.reverse!
    end

    def compute_topological_layers
      in_degree = Hash.new(0)
      @nodes.each { |n| fetch_set(@adjacency, n).each { |succ| in_degree[succ] += 1 } }

      queue = @nodes.select { |n| in_degree[n] == 0 }.sort
      processed = 0
      layers = []

      until queue.empty?
        layers << queue
        next_queue = []
        queue.each do |n|
          processed += 1
          fetch_set(@adjacency, n).each do |succ|
            in_degree[succ] -= 1
            next_queue << succ if in_degree[succ] == 0
          end
        end
        queue = next_queue.sort
      end

      raise CycleError, "Graph contains a cycle" if processed < @nodes.size
      layers
    end

    def initialize_dup(orig)
      super
      @nodes = @nodes.dup
      @adjacency = deep_dup_hash_of_sets(@adjacency)
      @reverse = deep_dup_hash_of_sets(@reverse)
      @edge_metadata = @edge_metadata.dup
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
      @edge_metadata.delete([from, to])
    end

    # Avoids auto-vivification on frozen hashes
    def fetch_set(hash, key)
      hash.fetch(key) { Set.new }
    end

    def walk(adjacency_hash, start, target: nil)
      visited = Set.new
      stack = fetch_set(adjacency_hash, start).to_a

      until stack.empty?
        current = stack.pop
        next if visited.include?(current)
        return true if target == current

        visited << current
        stack.concat(fetch_set(adjacency_hash, current).to_a)
      end

      target ? false : visited
    end

    def reachable?(from, to)
      walk(@adjacency, from, target: to)
    end

    def validate_edge_nodes!(from, to)
      raise UnknownNodeError, "Unknown node: #{from}" unless @nodes.include?(from)
      raise UnknownNodeError, "Unknown node: #{to}" unless @nodes.include?(to)
    end
  end
end
