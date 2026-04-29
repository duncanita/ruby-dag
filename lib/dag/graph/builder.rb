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

    # Fluent builder that produces a frozen Graph.
    # @api public
    class Builder
      # Yield a fresh Builder, then return its built (frozen) Graph.
      # @return [Graph]
      def self.build
        builder = new
        yield builder
        builder.build
      end

      def initialize
        @graph = Graph.new
      end

      # @return [self]
      def add_node(name)
        @graph.add_node(name)
        self
      end

      # @return [self]
      def add_edge(from, to, **metadata)
        @graph.add_edge(from, to, **metadata)
        self
      end

      # @return [Graph] frozen graph
      def build
        @graph.freeze
      end
    end
  end
end
