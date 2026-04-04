# frozen_string_literal: true

module DAG
  # The DAG itself. Holds nodes, validates acyclicity, computes execution order.
  #
  #   graph = DAG::Graph.new
  #   graph.add_node(name: :fetch, type: :exec, command: "curl ...")
  #   graph.add_node(name: :parse, type: :ruby, depends_on: [:fetch])
  #   graph.validate!     # raises if cyclic or missing deps
  #   graph.execution_order  # => [[:fetch], [:parse]]  (groups of parallelizable nodes)

  class Graph
    def initialize
      @nodes = {}
    end

    def add_node(node = nil, **kwargs)
      node = Node.new(**kwargs) if node.nil?
      raise ArgumentError, "Duplicate node: #{node.name}" if @nodes.key?(node.name)

      @nodes[node.name] = node
      self
    end

    def node(name) = @nodes[name.to_sym]
    def nodes = @nodes.values
    def size = @nodes.size
    def empty? = @nodes.empty?

    # Validate the graph: no cycles, no missing dependencies.
    # Returns self for chaining, raises on error.
    def validate!
      @nodes.each_value do |n|
        n.depends_on.each do |dep|
          raise ArgumentError, "Node #{n.name} depends on unknown node #{dep}" unless @nodes.key?(dep)
        end
      end

      detect_cycle!
      self
    end

    # Returns execution layers: each layer is an array of node names
    # that can run in parallel (all dependencies satisfied).
    #
    #   [[:a, :b], [:c], [:d]]
    #   Layer 0: a, b run in parallel
    #   Layer 1: c (depends on a or b)
    #   Layer 2: d (depends on c)
    def execution_order
      validate!

      remaining = @nodes.keys.to_set
      completed = Set.new
      layers = []

      until remaining.empty?
        # Find nodes whose dependencies are all completed
        ready = remaining.select do |name|
          @nodes[name].depends_on.all? { |dep| completed.include?(dep) }
        end

        raise "Deadlock: cannot resolve #{remaining.to_a}" if ready.empty?

        layers << ready.sort # sort for deterministic order
        ready.each do |name|
          remaining.delete(name)
          completed.add(name)
        end
      end

      layers
    end

    private

    # Kahn's algorithm for cycle detection
    def detect_cycle!
      in_degree = Hash.new(0)
      @nodes.each_value { |n| n.depends_on.each { |dep| in_degree[n.name] += 1 } }

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

      return if visited == @nodes.size

      raise CycleError, "Graph contains a cycle"
    end
  end

  class CycleError < StandardError; end
end
