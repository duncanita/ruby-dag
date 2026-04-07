# frozen_string_literal: true

module DAG
  # Pure DAG. Nodes are Symbols (anything `to_sym`able on input). Edges are
  # `Edge` Data values with optional metadata.
  #
  # ## Iteration
  #
  # Use `each_node` and `each_edge` explicitly. There is **no** `each` and
  # **no** `Enumerable` mixin — `graph.map`, `graph.count`, `graph.include?`
  # do not exist on purpose, because their meaning ("nodes? edges? both?") is
  # not obvious from the call site. Call `each_node`/`each_edge` (both return
  # an Enumerator when called without a block) and chain Enumerable on those:
  #
  #   graph.each_node.map { |n| n.upcase }
  #   graph.each_edge.count
  #
  # For cheap scalar queries prefer `node_count` / `edge_count` / `node?`.
  #
  # ## Mutation cost
  #
  # `add_edge` runs an O(V+E) reachability walk to reject cycles, so building
  # a graph node-by-node is O(V·(V+E)) total. That is fine for the workflow
  # graphs this library targets (tens to low thousands of nodes). If you are
  # importing a much larger graph from a trusted source, build it in one shot
  # and call `topological_layers` once at the end — that single call also
  # detects cycles in O(V+E).
  class Graph
    EMPTY_SET = Set.new.freeze
    private_constant :EMPTY_SET

    # Frozen snapshot of the node set. Mutating it never affects the graph.
    def nodes
      frozen? ? @nodes : @nodes.dup.freeze
    end

    def initialize
      @nodes = Set.new
      @adjacency = {}        # from → Set[to]
      @reverse = {}          # to → Set[from]
      @edge_metadata = {}    # [from, to] → Hash
    end

    # --- Mutation ---

    def add_node(name)
      check_frozen!
      sym = name.to_sym
      raise DuplicateNodeError, "Duplicate node: #{sym}" if @nodes.include?(sym)

      @nodes << sym
      self
    end

    # Adds a directed edge `from -> to`, with optional metadata stored on the
    # edge. Idempotent: re-adding an existing edge is a no-op (returns self
    # without raising and without overwriting metadata).
    #
    # Cost: O(V+E) per call, because we run a reachability walk from `to` back
    # to `from` to reject any insertion that would create a cycle. Building a
    # graph node-by-node is therefore O(V·(V+E)) total. That is fine for the
    # workflow graphs this library targets; if you are loading a much larger
    # graph from a trusted source and want to skip the per-insert cycle check,
    # build the structure yourself and call `topological_layers` once at the
    # end (it also detects cycles, in O(V+E)).
    def add_edge(from, to, **metadata)
      check_frozen!
      from_sym = from.to_sym
      to_sym = to.to_sym

      validate_edge_nodes!(from_sym, to_sym)
      raise ArgumentError, "Self-referencing edge: #{from_sym}" if from_sym == to_sym
      return self if fetch_set(@adjacency, from_sym).include?(to_sym)
      raise CycleError, "Edge #{from_sym} → #{to_sym} would create a cycle" if reachable?(to_sym, from_sym)

      insert_edge(from_sym, to_sym, metadata)
      self
    end

    def remove_node(name)
      check_frozen!
      sym = name.to_sym
      raise UnknownNodeError, "Unknown node: #{sym}" unless @nodes.include?(sym)

      fetch_set(@adjacency, sym).each do |to|
        @reverse[to]&.delete(sym)
        @edge_metadata.delete([sym, to])
      end
      fetch_set(@reverse, sym).each do |from|
        @adjacency[from]&.delete(sym)
        @edge_metadata.delete([from, sym])
      end

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

    # Renames a node, preserving every incident edge and its metadata. The
    # rewiring is done by manipulating the adjacency hashes directly rather
    # than going through `add_edge`, because `add_edge` would re-run cycle
    # detection on each re-added edge — pointless work, since renaming a node
    # in place cannot introduce a cycle that wasn't already there.
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
      @nodes << new_sym

      incoming.each { |pred, meta| insert_edge(pred, new_sym, meta) }
      outgoing.each { |succ, meta| insert_edge(new_sym, succ, meta) }

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

    # Prefer `node_count` / `edge_count` over `size` / `count` in code that
    # cares which it's measuring. `size` is the node count (kept for symmetry
    # with collection types); `count` comes from `Enumerable` and also iterates
    # nodes via `each = each_node`.
    def node_count = @nodes.size

    def edge_count
      n = 0
      @adjacency.each_value { |s| n += s.size }
      n
    end

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
      fetch_set(@reverse, sym).each_with_object(Set.new) do |from, set|
        set << Edge.new(from: from, to: sym, metadata: edge_metadata(from, sym))
      end
    end

    def edge_metadata(from, to)
      @edge_metadata.fetch([from.to_sym, to.to_sym], {})
    end

    # --- Neighbor queries ---

    def successors(name) = fetch_set(@adjacency, name.to_sym).dup
    def predecessors(name) = fetch_set(@reverse, name.to_sym).dup

    def roots = frozen? ? @cached_roots : nodes_with_no(@reverse)
    def leaves = frozen? ? @cached_leaves : nodes_with_no(@adjacency)

    # Root/leaf iteration convenience. Useful when the caller wants ordered
    # iteration (insertion order) rather than a Set.
    def each_root(&block) = roots.each(&block)
    def each_leaf(&block) = leaves.each(&block)

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

    # Shortest path from `from` to `to` as `{cost:, path:}`, or `nil` if
    # `to` is unreachable. Edge cost comes from the `:weight` metadata key
    # on each edge (`add_edge(:a, :b, weight: 4)`); edges without `:weight`
    # default to cost 1.
    def shortest_path(from, to)
      weighted_path(from, to, Float::INFINITY) { |a, b| a < b }
    end

    # Longest path from `from` to `to` as `{cost:, path:}`, or `nil` if
    # unreachable. Uses the same `:weight` edge-metadata convention as
    # `shortest_path` (unweighted edges default to cost 1). Safe on DAGs
    # because topological order turns longest-path into a relaxation.
    def longest_path(from, to)
      weighted_path(from, to, -Float::INFINITY) { |a, b| a > b }
    end

    # Critical path: the longest root-to-leaf path through the whole DAG,
    # as `{cost:, path:}`. Uses the same `:weight` convention — unweighted
    # edges default to cost 1, so on a plain unweighted DAG this returns
    # the longest edge-count chain.
    def critical_path
      return nil if empty?

      dist, pred = relax(roots, -Float::INFINITY) { |a, b| a > b }
      target = leaves.max_by { |l| dist[l] }
      {cost: dist[target], path: rebuild_path(pred, target)}
    end

    # --- Iteration ---
    #
    # `each_node` and `each_edge` are the ONLY iteration entry points.
    # Graph does NOT include Enumerable: `graph.map`, `graph.count`,
    # `graph.include?` etc. are intentionally absent because their meaning
    # (nodes? edges?) is not obvious from the call site. Both `each_node` and
    # `each_edge` return an `Enumerator` when called without a block, so
    # `graph.each_node.map { ... }` / `graph.each_edge.count` give you the
    # Enumerable surface explicitly.

    def each_node(&block)
      return enum_for(:each_node) unless block
      @nodes.each(&block)
    end

    def each_edge(&block)
      return enum_for(:each_edge) unless block
      edges.each(&block)
    end

    # Read-only iteration over predecessors without duping the internal Set.
    def each_predecessor(name, &block)
      return enum_for(:each_predecessor, name) unless block
      fetch_set(@reverse, name.to_sym).each(&block)
    end

    # --- Subgraph ---

    def subgraph(node_names)
      keep = node_names.map(&:to_sym).to_set
      raise ArgumentError, "Unknown nodes: #{(keep - @nodes).to_a}" unless keep.subset?(@nodes)

      add_nodes_to(Graph.new, keep).then { |g| copy_internal_edges(g, keep) }
    end

    # Renders the graph in Graphviz DOT format. Node and graph names are
    # quoted whenever they contain anything outside `[A-Za-z0-9_]` (or start
    # with a digit), and any embedded `"` / `\` characters in node labels are
    # escaped. This means symbols like `:"my node"`, `:foo-bar`, or `:1st`
    # produce valid DOT instead of a parse error in `dot(1)`.
    def to_dot(name: "dag")
      sorted = topological_sort
      lines = ["digraph #{dot_id(name)} {"]
      sorted.each { |n| lines << "  #{dot_id(n)};" }
      sorted.each do |from|
        fetch_set(@adjacency, from).sort.each do |to|
          meta = edge_metadata(from, to)
          if meta.empty?
            lines << "  #{dot_id(from)} -> #{dot_id(to)};"
          else
            label = meta.map { |k, v| "#{k}=#{v}" }.join(", ")
            lines << "  #{dot_id(from)} -> #{dot_id(to)} [label=#{dot_quote(label)}];"
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

    # Equality is structural: two Graphs are equal iff they have the same node
    # set and the same edge set (with the same metadata). It works on frozen
    # AND unfrozen graphs alike — no FrozenError surprises.
    #
    # CAVEAT: a graph's identity is its node + edge set. If you store an
    # unfrozen Graph as a Hash key or Set member and then mutate it, you will
    # break the container's invariants (the bucket index won't match anymore).
    # Freeze before using as a key. The library can't enforce that for you
    # without making `==` itself misbehave, which is the worse trade.
    def ==(other)
      return false unless other.is_a?(Graph)
      @nodes == other.nodes && edges == other.edges
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

    def add_nodes_to(graph, names)
      names.each { |n| graph.add_node(n) }
      graph
    end

    # Source is a valid DAG, so skip the per-insert cycle check.
    def copy_internal_edges(graph, keep)
      keep.each do |from|
        fetch_set(@adjacency, from).each do |to|
          next unless keep.include?(to)
          graph.send(:insert_edge, from, to, edge_metadata(from, to))
        end
      end
      graph
    end

    # Returns a Set of nodes whose entry in `hash` is empty (no
    # successors / predecessors). Set is the right type here so that
    # `roots`/`leaves` are consistent with `successors`/`predecessors`.
    # Iteration order is the underlying Set order (insertion order).
    def nodes_with_no(hash)
      @nodes.each_with_object(Set.new) do |n, set|
        set << n if fetch_set(hash, n).empty?
      end
    end

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
      @adjacency = @adjacency.transform_values(&:dup)
      @reverse = @reverse.transform_values(&:dup)
      @edge_metadata = @edge_metadata.dup
    end

    def check_frozen!
      raise FrozenError, "can't modify frozen #{self.class}" if frozen?
    end

    def remove_edge_internal(from, to)
      @adjacency[from]&.delete(to)
      @reverse[to]&.delete(from)
      @edge_metadata.delete([from, to])
    end

    # Inserts an edge into the adjacency hashes WITHOUT cycle detection or
    # validation. Used by `replace_node`, where the edges being re-added are
    # already known to belong to a valid DAG. Do not call this from anywhere
    # that doesn't have that guarantee.
    def insert_edge(from, to, metadata)
      (@adjacency[from] ||= Set.new) << to
      (@reverse[to] ||= Set.new) << from
      @edge_metadata[[from, to]] = metadata.freeze unless metadata.empty?
    end

    DOT_BARE_ID = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    private_constant :DOT_BARE_ID

    # Returns a DOT-safe identifier for `name`. Symbols / strings made of
    # `[A-Za-z_][A-Za-z0-9_]*` are emitted bare (the common case). Anything
    # else gets wrapped in double quotes with `"` and `\` escaped.
    def dot_id(name)
      str = name.to_s
      DOT_BARE_ID.match?(str) ? str : dot_quote(str)
    end

    def dot_quote(str)
      escaped = str.gsub("\\", "\\\\\\\\").gsub('"', '\\"')
      %("#{escaped}")
    end

    # Avoids auto-vivification on frozen hashes. Returns a shared frozen
    # empty Set on miss; callers must not mutate the returned value (we
    # only ever iterate or take .size on it).
    def fetch_set(hash, key)
      hash.fetch(key, EMPTY_SET)
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
