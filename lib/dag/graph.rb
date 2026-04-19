# frozen_string_literal: true

module DAG
  # The DAG. Holds nodes, validates acyclicity, computes execution layers.
  #
  #   graph = DAG::Graph.new
  #     .add_node(name: :fetch, type: :exec, command: "curl ...")
  #     .add_node(name: :parse, type: :ruby, depends_on: [:fetch])
  #
  #   graph.execution_order  # => [[:fetch], [:parse]]
  #
  # ## Dynamic Mutation
  #
  # Graphs are immutable — mutation operations return a new graph instance.
  # Use {MutationResult} from {#replace_subtree} and {SubtreeImpact} from
  # {#subtree_replacement_impact} to preview and apply structural changes.
  #
  #   impact = graph.subtree_replacement_impact(:deploy, new_subgraph)
  #   result = graph.replace_subtree(:deploy, new_subgraph)
  #   DAG::Runner.new(result.new_graph).call
  #
  class Graph
    def initialize
      @nodes = {}
    end

    def add_node(**kwargs)
      Node.new(**kwargs)
        .then { |node| validate_unique!(node) }
        .then { |node| store(node) }

      self
    end

    def node(name) = @nodes[name.to_sym]
    def nodes = @nodes.values
    def size = @nodes.size
    def empty? = @nodes.empty?

    # Returns all node names in the graph.
    def node_names = @nodes.keys.to_set

    def validate!
      validate_dependencies!
      detect_cycle!
      self
    end

    # Execution layers: nodes in each layer can run in parallel.
    # [[:a, :b], [:c], [:d]]
    def execution_order
      validate!
      build_layers
    end

    # ---------------------------------------------------------------------
    # Dynamic mutation — subtree replacement
    # ---------------------------------------------------------------------

    # Preview the impact of replacing the subtree rooted at +boundary_node_name+.
    #
    # Does not modify the graph. Returns a {SubtreeImpact} describing
    # affected downstream nodes and any that have file-write side effects
    # (making their artifacts potentially stale after a re-run).
    #
    #   impact = graph.subtree_replacement_impact(:deploy, new_subgraph)
    #   puts "Downstream: #{impact.affected_nodes}"
    #   puts "May be stale: #{impact.stale_nodes}"
    #
    def subtree_replacement_impact(boundary_node_name, _replacement_subgraph)
      boundary = boundary_node_name.to_sym
      raise ArgumentError, "Unknown node: #{boundary}" unless @nodes.key?(boundary)

      # All downstream nodes that depend on the boundary (directly or transitively)
      downstream = transitive_dependents(boundary)

      # Among downstream nodes, flag those with file-write side effects as stale
      stale = downstream.select { |name| @nodes[name].type == :file_write }.to_set

      SubtreeImpact.new(
        affected_nodes: downstream.to_a.sort,
        stale_nodes: stale.to_a.sort,
        boundary_node: boundary,
        replacement_size: 0,
        is_safe: downstream.empty?
      )
    end

    # Replace the subtree rooted at +boundary_node_name+ with the nodes
    # from +replacement_subgraph+.
    #
    # The replacement_subgraph's root node must carry the same name as
    # +boundary_node_name+ and declare the same dependencies so that
    # consumers of the boundary remain valid.
    #
    # Downstream nodes (that depend on the boundary) are PRESERVED in the
    # new graph. They are reported in +stale_nodes+ if they have file-write
    # side effects whose artifacts may be stale after a re-run.
    #
    # Returns a {MutationResult}. On success, +new_graph+ is a fresh Graph
    # with the replacement applied. On failure, +error+ describes why.
    #
    #   result = graph.replace_subtree(:deploy, new_deploy_graph)
    #   if result.success?
    #     DAG::Runner.new(result.new_graph).call
    #   end
    #
    def replace_subtree(boundary_node_name, replacement_subgraph)
      boundary = boundary_node_name.to_sym

      # --- validate boundary exists ---
      unless @nodes.key?(boundary)
        return MutationResult.failure("Boundary node '#{boundary}' not found in graph")
      end

      # --- validate replacement is a Graph ---
      unless replacement_subgraph.is_a?(Graph)
        return MutationResult.failure("Replacement must be a DAG::Graph instance")
      end

      # --- replacement must contain the boundary as its root ---
      unless replacement_subgraph.node(boundary)
        return MutationResult.failure(
          "Replacement subgraph must contain a node named '#{boundary}' " \
          "(the new root of the replaced subtree)"
        )
      end

      # --- replacement root must declare the same dependencies as the original ---
      original_deps = @nodes[boundary].depends_on
      replacement_root_deps = replacement_subgraph.node(boundary).depends_on
      if original_deps != replacement_root_deps
        return MutationResult.failure(
          "Replacement node '#{boundary}' must declare the same dependencies " \
          "as the original (#{original_deps.map(&:to_s).join(", ")}). " \
          "Got: #{replacement_root_deps.map(&:to_s).join(", ")}"
        )
      end

      # --- identify what is replaced ---
      # The boundary and its ancestors form the old subtree being replaced.
      old_subtree = ancestors(boundary)
      # All nodes that depend on the boundary in the original graph.
      # These are preserved in the new graph (their inputs may change).
      downstream = transitive_dependents(boundary)

      # --- build the new node map ---
      new_nodes = {}

      # 1. Add replacement nodes first so boundary dependencies are satisfied
      #    and take precedence over any same-name original nodes.
      replacement_subgraph.nodes.each { |node| new_nodes[node.name] = node }

      # 2. Copy original nodes that are not in the old subtree and not already
      #    provided by the replacement.  Replacement nodes always take precedence
      #    (even when they share a name with a downstream original node) so
      #    that cycles within the replacement are detected and so that same-name
      #    boundary/ancestor nodes from the old graph never survive the merge.
      @nodes.each do |name, node|
        new_nodes[name] = node unless old_subtree.include?(name) ||
                                     new_nodes.key?(name)
      end

      # --- build the new graph ---
      new_graph = Graph.new
      new_nodes.each_value do |node|
        new_graph.add_node(
          name: node.name,
          type: node.type,
          depends_on: node.depends_on,
          **node.config
        )
      end

      # Validate the new graph (acyclicity + well-formedness)
      begin
        new_graph.validate!
      rescue CycleError => e
        return MutationResult.failure("Replacement creates a cycle: #{e.message}")
      rescue ArgumentError => e
        return MutationResult.failure("Replacement creates invalid graph: #{e.message}")
      end

      # --- compute delta ---
      old_names = @nodes.keys.to_set
      new_names = new_graph.node_names
      removed_nodes = (old_names - new_names).to_a.sort
      added_nodes = (new_names - old_names).to_a.sort

      # --- stale nodes ---
      # Downstream nodes with file-write side effects may have stale artifacts.
      # Use the ORIGINAL graph's types so that same-name replacement nodes
      # don't obscure whether the original downstream node was a file writer.
      stale = downstream.select { |name| @nodes[name]&.type == :file_write }.to_set

      MutationResult.success(
        new_graph: new_graph,
        added_nodes: added_nodes,
        removed_nodes: removed_nodes,
        stale_nodes: stale.to_a.sort
      )
    end

    # ---------------------------------------------------------------------
    # Graph traversal helpers
    # ---------------------------------------------------------------------

    # Returns the set of all nodes (transitively) reachable from +node_name+
    # by following +depends_on+ edges inward.
    #
    #   graph.ancestors(:c)  # => #{:a, :b, :c}  for a -> b -> c
    #
    def ancestors(node_name)
      node = node_name.to_sym
      visited = Set.new
      queue = [node]

      until queue.empty?
        current = queue.shift
        next if visited.include?(current)
        visited.add(current)
        @nodes[current]&.depends_on&.each { |dep| queue << dep unless visited.include?(dep) }
      end

      visited
    end

    # Returns the set of all nodes that (transitively) depend on +node_name+.
    #
    #   graph.transitive_dependents(:a)  # => #{:b, :c, :d}  for a -> b -> d, a -> c -> d
    #
    def transitive_dependents(node_name)
      node = node_name.to_sym
      visited = Set.new
      queue = [node]

      until queue.empty?
        current = queue.shift
        @nodes.each_value do |n|
          next unless n.depends_on.include?(current)
          next if visited.include?(n.name)

          visited.add(n.name)
          queue << n.name
        end
      end

      visited.delete(node)
      visited
    end

    private

    def validate_unique!(node)
      raise ArgumentError, "Duplicate node: #{node.name}" if @nodes.key?(node.name)

      node
    end

    def store(node)
      @nodes[node.name] = node
    end

    def validate_dependencies!
      @nodes.each_value do |n|
        n.depends_on.each do |dep|
          raise ArgumentError, "Node #{n.name} depends on unknown node #{dep}" unless @nodes.key?(dep)
        end
      end
    end

    def build_layers
      remaining = @nodes.keys.to_set
      completed = Set.new
      layers = []

      until remaining.empty?
        ready = remaining.select { |name| deps_satisfied?(name, completed) }
        raise "Deadlock: cannot resolve #{remaining.to_a}" if ready.empty?

        layers << ready.sort
        ready.each { |name|
          remaining.delete(name)
          completed.add(name)
        }
      end

      layers
    end

    def deps_satisfied?(name, completed)
      @nodes[name].depends_on.all? { |dep| completed.include?(dep) }
    end

    # Kahn's algorithm
    def detect_cycle!
      in_degree = Hash.new(0)
      @nodes.each_value { |n| n.depends_on.each { in_degree[n.name] += 1 } }

      queue = @nodes.keys.select { |name| in_degree[name] == 0 }
      visited = 0

      until queue.empty?
        current = queue.shift
        visited += 1

        @nodes.each_value do |n|
          next unless n.depends_on.include?(current)

          in_degree[n.name] -= 1
          queue << n.name if in_degree[n.name] == 0
        end
      end

      raise CycleError, "Graph contains a cycle" unless visited == @nodes.size
    end
  end
end
