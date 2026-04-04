# frozen_string_literal: true

module DAG
  # The DAG. Holds nodes, validates acyclicity, computes execution layers.
  #
  #   graph = DAG::Graph.new
  #     .add_node(name: :fetch, type: :exec, command: "curl ...")
  #     .add_node(name: :parse, type: :ruby, depends_on: [:fetch])
  #
  #   graph.execution_order  # => [[:fetch], [:parse]]

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

    def validate!
      validate_dependencies!
      build_layers_with_cycle_check
      self
    end

    # Execution layers: nodes in each layer can run in parallel.
    # [[:a, :b], [:c], [:d]]
    def execution_order
      validate_dependencies!
      build_layers_with_cycle_check
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

    # Kahn's algorithm: topological sort into layers + cycle detection in one pass.
    # O(V+E) using precomputed adjacency list.
    def build_layers_with_cycle_check
      dependents = build_dependents_map
      in_degree = build_in_degree_map

      remaining = @nodes.keys.to_set
      layers = []

      until remaining.empty?
        ready = remaining.select { |name| in_degree[name] == 0 }
        raise CycleError, "Graph contains a cycle" if ready.empty?

        layers << ready.sort

        ready.each do |name|
          remaining.delete(name)
          dependents[name].each { |dep| in_degree[dep] -= 1 }
        end
      end

      layers
    end

    # Map: node_name => [nodes that depend on it]
    def build_dependents_map
      map = Hash.new { |h, k| h[k] = [] }
      @nodes.each_value { |n| n.depends_on.each { |dep| map[dep] << n.name } }
      map
    end

    # Map: node_name => number of unresolved dependencies
    def build_in_degree_map
      @nodes.keys.to_h { |name| [name, @nodes[name].depends_on.size] }
    end
  end
end
