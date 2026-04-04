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
      detect_cycle!
      self
    end

    # Execution layers: nodes in each layer can run in parallel.
    # [[:a, :b], [:c], [:d]]
    def execution_order
      validate!
      build_layers
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
