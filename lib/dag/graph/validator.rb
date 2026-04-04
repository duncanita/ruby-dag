# frozen_string_literal: true

module DAG
  class Graph
    # Validates a Graph for structural issues beyond basic acyclicity.
    # Collects all errors rather than failing on the first.
    #
    #   result = DAG::Graph::Validator.validate(graph) do |v|
    #     v.rule("must have a single root") { |g| g.roots.size == 1 }
    #   end
    #
    #   result.valid?  # => true/false
    #   result.errors  # => ["Node c is disconnected", ...]

    Result = Data.define(:errors) do
      def valid? = errors.empty?
    end

    class Validator
      def self.validate(graph, &block)
        validator = new(graph)
        block&.call(validator)
        validator.run
      end

      def self.validate!(graph, &block)
        result = validate(graph, &block)
        raise ValidationError, result.errors unless result.valid?
        graph
      end

      def initialize(graph)
        @graph = graph
        @custom_rules = []
      end

      def rule(message, &block)
        @custom_rules << [message, block]
      end

      def run
        errors = []
        check_disconnected(errors)
        check_custom_rules(errors)
        Result.new(errors: errors.freeze)
      end

      private

      def check_disconnected(errors)
        return if @graph.size <= 1

        @graph.nodes.each do |node|
          if @graph.predecessors(node).empty? && @graph.successors(node).empty?
            errors << "Node #{node} is disconnected"
          end
        end
      end

      def check_custom_rules(errors)
        @custom_rules.each do |message, check|
          errors << message unless check.call(@graph)
        end
      end
    end
  end
end
