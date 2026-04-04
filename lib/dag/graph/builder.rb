# frozen_string_literal: true

module DAG
  class Graph
    # Fluent builder that produces a frozen Graph.
    #
    #   graph = DAG::Graph::Builder.build do |b|
    #     b.add_node(:a)
    #     b.add_node(:b)
    #     b.add_edge(:a, :b)
    #   end
    #
    #   graph.frozen? # => true

    class Builder
      def self.build
        builder = new
        yield builder
        builder.build
      end

      def initialize
        @graph = Graph.new
      end

      def add_node(name)
        @graph.add_node(name)
        self
      end

      def add_edge(from, to)
        @graph.add_edge(from, to)
        self
      end

      def build
        @graph.freeze
      end
    end
  end
end
