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
          errors.concat(Condition.validate(
            step.config[:run_if],
            node_name: node,
            graph: graph,
            allowed_inputs: allowed_condition_inputs(graph, step, node_name: node)
          ))
          errors.concat(validate_dependency_inputs(graph, step, node_name: node))
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

      def self.validate_dependency_inputs(graph, step, node_name:)
        local_errors = graph.each_predecessor(node_name).each_with_object([]) do |dependency_name, errors|
          metadata = graph.edge_metadata(dependency_name, node_name)
          validate_dependency_version(metadata[:version], dependency_name: dependency_name, node_name: node_name, errors: errors) if metadata.key?(:version)
        end

        external_errors = Array(step.config[:external_dependencies]).each_with_object([]) do |dependency, errors|
          validate_external_dependency(dependency, node_name: node_name, errors: errors)
          validate_dependency_version(dependency[:version], dependency_name: "#{dependency[:workflow_id]}.#{dependency[:node]}", node_name: node_name, errors: errors) if dependency.key?(:version)
        end

        local_errors + external_errors + duplicate_effective_input_key_errors(graph, step, node_name: node_name)
      end

      def self.validate_dependency_version(version, dependency_name:, node_name:, errors:)
        return if version == :latest || version == :all || (version.is_a?(Integer) && version.positive?)

        errors << "Node #{node_name} dependency #{dependency_name} has invalid version #{version.inspect}; expected :latest, :all, or a positive Integer"
      end

      def self.validate_external_dependency(dependency, node_name:, errors:)
        if blank?(dependency[:workflow_id]) || blank?(dependency[:node])
          errors << "Node #{node_name} has invalid external dependency #{dependency.inspect}; expected workflow_id and node"
        end
      end

      def self.allowed_condition_inputs(graph, step, node_name:)
        graph.predecessors(node_name) + Array(step.config[:external_dependencies]).map do |dependency|
          (dependency[:as] || dependency[:node]).to_sym
        end
      end

      def self.duplicate_effective_input_key_errors(graph, step, node_name:)
        keys = graph.each_predecessor(node_name).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |dependency_name, memo|
          metadata = graph.edge_metadata(dependency_name, node_name)
          key = (metadata[:as] || dependency_name).to_sym
          memo[key] << dependency_name
        end

        Array(step.config[:external_dependencies]).each do |dependency|
          key = (dependency[:as] || dependency[:node]).to_sym
          keys[key] << "#{dependency[:workflow_id]}.#{dependency[:node]}"
        end

        keys.filter_map do |key, dependencies|
          next unless dependencies.size > 1

          "Node #{node_name} has duplicate effective input key #{key.inspect} from dependencies #{dependencies.sort_by(&:to_s).inspect}"
        end
      end

      def self.blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end
  end
end
