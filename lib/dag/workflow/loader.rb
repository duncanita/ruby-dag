# frozen_string_literal: true

require "yaml"

module DAG
  module Workflow
    # Loads a workflow from YAML, producing a Graph + Registry.
    #
    #   definition = DAG::Workflow::Loader.from_file("workflow.yml")
    #   definition.graph     # => DAG::Graph
    #   definition.registry  # => DAG::Workflow::Registry

    class Loader
      VALID_TYPES = %w[exec script file_read file_write ruby llm].freeze

      def self.from_file(path)
        raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

        File.read(path)
          .then { |content| from_yaml(content) }
      end

      def self.from_yaml(yaml_string)
        YAML.safe_load(yaml_string, permitted_classes: [Symbol])
          .then { |data| validate_structure(data) }
          .then { |data| build_workflow(data) }
      end

      def self.validate_structure(data)
        raise ArgumentError, "YAML must contain 'nodes' key" unless data&.key?("nodes")

        data
      end

      def self.build_workflow(data)
        graph = Graph.new
        registry = Registry.new
        deferred_edges = []

        data["nodes"].each do |name, config|
          config = config.dup
          type = config.delete("type") || raise(ArgumentError, "Node '#{name}' missing 'type'")
          validate_type!(name, type)

          depends_on = Array(config.delete("depends_on"))

          graph.add_node(name)
          registry.register(Step.new(name: name, type: type, **config.transform_keys(&:to_sym)))

          depends_on.each { |dep| deferred_edges << [dep.to_sym, name.to_sym] }
        end

        deferred_edges.each do |from, to|
          raise ArgumentError, "Node #{to} depends on unknown node #{from}" unless graph.node?(from)
          graph.add_edge(from, to)
        end

        Definition.new(graph: graph, registry: registry)
      end

      def self.validate_type!(name, type)
        return if VALID_TYPES.include?(type)

        raise ArgumentError, "Node '#{name}' has invalid type '#{type}'. Valid: #{VALID_TYPES.join(", ")}"
      end

      private_class_method :validate_structure, :build_workflow, :validate_type!
    end
  end
end
