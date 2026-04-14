# frozen_string_literal: true

module DAG
  module Workflow
    ValidationReport = Data.define(:errors) do
      def initialize(errors:)
        super(errors: errors.freeze)
      end

      def valid? = errors.empty?
    end

    class Validator
      def self.validate(graph, registry)
        errors = []

        graph.each_node do |node|
          next unless registry.key?(node)

          errors.concat(Condition.validate(registry[node].config[:run_if], node_name: node, graph: graph))
        end

        ValidationReport.new(errors: errors)
      end

      def self.validate!(graph, registry)
        report = validate(graph, registry)
        raise ValidationError, report.errors unless report.valid?

        [graph, registry]
      end
    end
  end
end
