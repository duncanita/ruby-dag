# frozen_string_literal: true

module DAG
  class Graph
    # Computes execution plans from a Graph.
    # Separates planning logic from the graph data structure.
    #
    #   planner = DAG::Graph::Planner.new(graph)
    #   planner.layers     # => [[:a], [:b, :c], [:d]]
    #   planner.flat_order # => [:a, :b, :c, :d]

    class Planner
      def initialize(graph)
        @graph = graph
      end

      # Kahn's algorithm: topological sort into parallel layers.
      # Nodes in each layer can run concurrently.
      def layers
        @graph.topological_sort
      end

      # Flat deterministic topological ordering.
      def flat_order
        layers.flatten
      end

      def each_layer(&block)
        return enum_for(:each_layer) unless block
        layers.each(&block)
      end
    end
  end
end
