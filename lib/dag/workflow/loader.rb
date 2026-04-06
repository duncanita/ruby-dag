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
          validate_type!(name, type.to_sym, valid_types: Steps.yaml_types)

          depends_on = parse_depends_on(config.delete("depends_on"))
          [name.to_sym, {type: type.to_sym, depends_on: depends_on, **config.transform_keys(&:to_sym)}]
        end

        build_definition(entries)
      end

      def self.from_hash(**node_defs)
        entries = node_defs.map do |name, opts|
          opts = opts.dup
          type = opts.delete(:type) || raise(ArgumentError, "Node '#{name}' missing 'type'")
          validate_type!(name, type.to_sym)

          depends_on = parse_depends_on(opts.delete(:depends_on))
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
          depends_on.each { |dep| deferred_edges << dep.merge(to: name) }
        end

        deferred_edges.each do |edge|
          from = edge[:from]
          to = edge[:to]
          metadata = edge.except(:from, :to)
          raise ArgumentError, "Node #{to} depends on unknown node #{from}" unless graph.node?(from)
          graph.add_edge(from, to, **metadata)
        end

        Definition.new(graph: graph, registry: registry)
      end

      def self.validate_type!(name, type, valid_types: Steps.types)
        return if valid_types.include?(type)

        if Steps.types.include?(type) && !valid_types.include?(type)
          raise ArgumentError, "Node '#{name}' has type '#{type}' which is not supported in YAML. Use from_hash for programmatic step types."
        end

        raise ArgumentError, "Node '#{name}' has invalid type '#{type}'. Valid: #{valid_types.join(", ")}"
      end

      def self.parse_depends_on(raw)
        Array(raw).map do |dep|
          case dep
          when Hash
            dep.transform_keys(&:to_sym).tap { |h| h[:from] = h[:from].to_sym }
          when String, Symbol
            {from: dep.to_sym}
          else
            {from: dep.to_sym}
          end
        end
      end

      private_class_method :build_definition, :validate_type!, :parse_depends_on
    end
  end
end
