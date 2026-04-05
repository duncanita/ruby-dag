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
      YAML_TYPES = %i[exec ruby_script file_read file_write]
      ALL_TYPES = YAML_TYPES + %i[ruby]

      def self.from_file(path)
        raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

        File.read(path)
          .then { |content| from_yaml(content) }
      end

      def self.from_yaml(yaml_string)
        data = YAML.safe_load(yaml_string, permitted_classes: [Symbol])
        raise ArgumentError, "YAML must contain 'nodes' key" unless data&.key?("nodes")

        entries = data["nodes"].map do |name, config|
          config = config.dup
          type = config.delete("type") || raise(ArgumentError, "Node '#{name}' missing 'type'")
          validate_type!(name, type.to_sym, valid_types: YAML_TYPES)

          depends_on = Array(config.delete("depends_on")).map { |d| d.to_sym }
          [name.to_sym, {type: type.to_sym, depends_on: depends_on, **config.transform_keys(&:to_sym)}]
        end

        build_definition(entries)
      end

      def self.from_hash(**node_defs)
        entries = node_defs.map do |name, opts|
          opts = opts.dup
          type = opts.delete(:type) || raise(ArgumentError, "Node '#{name}' missing 'type'")
          validate_type!(name, type.to_sym)

          depends_on = Array(opts.delete(:depends_on)).map { |d| d.to_sym }
          [name.to_sym, {type: type.to_sym, depends_on: depends_on, **opts}]
        end

        build_definition(entries)
      end

      def self.build_definition(entries)
        graph = Graph.new
        registry = Registry.new
        deferred_edges = []

        entries.each do |name, opts|
          opts = opts.dup
          depends_on = opts.delete(:depends_on)
          type = opts.delete(:type)

          graph.add_node(name)
          registry.register(Step.new(name: name, type: type, **opts))
          depends_on.each { |dep| deferred_edges << [dep, name] }
        end

        deferred_edges.each do |from, to|
          raise ArgumentError, "Node #{to} depends on unknown node #{from}" unless graph.node?(from)
          graph.add_edge(from, to)
        end

        Definition.new(graph: graph, registry: registry)
      end

      def self.validate_type!(name, type, valid_types: ALL_TYPES)
        return if valid_types.include?(type)

        if ALL_TYPES.include?(type) && !valid_types.include?(type)
          raise ArgumentError, "Node '#{name}' has type '#{type}' which is not supported in YAML. Use from_hash for programmatic step types."
        end

        raise ArgumentError, "Node '#{name}' has invalid type '#{type}'. Valid: #{valid_types.join(", ")}"
      end

      private_class_method :build_definition, :validate_type!
    end
  end
end
