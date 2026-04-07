# frozen_string_literal: true

module DAG
  class Graph
    # Validates a Graph for structural issues beyond basic acyclicity.
    # Collects all errors rather than failing on the first.
    #
    #   report = DAG::Graph::Validator.validate(graph) do |v|
    #     v.rule("must have a single root") { |g| g.roots.size == 1 }
    #   end
    #
    #   report.valid?  # => true/false
    #   report.errors  # => ["Node c is disconnected", ...]

    Report = Data.define(:errors) do
      def valid? = errors.empty?
    end

    class Validator
      def self.validate(graph, &block)
        validator = new(graph)
        block&.call(validator)
        validator.run
      end

      def self.validate!(graph, &block)
        report = validate(graph, &block)
        raise ValidationError, report.errors unless report.valid?
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
        check_isolated_nodes(errors)
        check_custom_rules(errors)
        Report.new(errors: errors.freeze)
      end

      private

      # A node is "isolated" only in a multi-node graph where it has no edges.
      # A single-node graph is trivially valid: the lone node is both root and
      # leaf, and an empty graph has nothing to check.
      def check_isolated_nodes(errors)
        return if @graph.size <= 1

        @graph.nodes.each do |node|
          next unless @graph.predecessors(node).empty? && @graph.successors(node).empty?

          errors << "Node #{node} is isolated (no edges)"
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
