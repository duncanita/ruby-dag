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

          step = registry[node]
          errors.concat(Condition.validate(step.config[:run_if], node_name: node, graph: graph))
          errors.concat(validate_dependency_inputs(graph, node_name: node))
          errors.concat(validate_sub_workflow(step, node_name: node)) if step.type == :sub_workflow
        end

        ValidationReport.new(errors: errors)
      end

      def self.validate!(graph, registry)
        report = validate(graph, registry)
        raise ValidationError, report.errors unless report.valid?

        [graph, registry]
      end

      def self.validate_sub_workflow(step, node_name:)
        SubWorkflowSupport.validate(step, node_name: node_name)
      end

      def self.validate_dependency_inputs(graph, node_name:)
        graph.each_predecessor(node_name).each_with_object([]) do |dependency_name, errors|
          metadata = graph.edge_metadata(dependency_name, node_name)
          validate_dependency_version(metadata[:version], dependency_name: dependency_name, node_name: node_name, errors: errors) if metadata.key?(:version)
        end.concat(duplicate_effective_input_key_errors(graph, node_name: node_name))
      end

      def self.validate_dependency_version(version, dependency_name:, node_name:, errors:)
        return if version == :latest || version == :all || (version.is_a?(Integer) && version.positive?)

        errors << "Node #{node_name} dependency #{dependency_name} has invalid version #{version.inspect}; expected :latest, :all, or a positive Integer"
      end

      def self.duplicate_effective_input_key_errors(graph, node_name:)
        graph.each_predecessor(node_name).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |dependency_name, keys|
          metadata = graph.edge_metadata(dependency_name, node_name)
          key = (metadata[:as] || dependency_name).to_sym
          keys[key] << dependency_name
        end.filter_map do |key, dependencies|
          next unless dependencies.size > 1

          "Node #{node_name} has duplicate effective input key #{key.inspect} from dependencies #{dependencies.sort.inspect}"
        end
      end
    end
  end
end
