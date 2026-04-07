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
        from_yaml(File.read(path))
      rescue Errno::ENOENT
        raise ArgumentError, "File not found: #{path}"
      end

      def self.from_yaml(yaml_string)
        data = YAML.safe_load(yaml_string)
        raise ValidationError, "YAML must contain 'nodes' key" unless data&.key?("nodes")

        build_definition(normalize_entries(data["nodes"], string_keys: true))
      end

      def self.from_hash(**node_defs)
        build_definition(normalize_entries(node_defs, string_keys: false))
      end

      def self.normalize_entries(node_defs, string_keys:)
        type_key = string_keys ? "type" : :type
        depends_key = string_keys ? "depends_on" : :depends_on
        valid_types = string_keys ? Steps.yaml_types : Steps.types

        node_defs.map do |name, opts|
          opts = opts.dup
          type = opts.delete(type_key) || raise(ValidationError, "Node '#{name}' missing 'type'")
          validate_type!(name, type.to_sym, valid_types: valid_types)

          depends_on = parse_depends_on(opts.delete(depends_key))
          rest = string_keys ? opts.transform_keys(&:to_sym) : opts
          [name.to_sym, {type: type.to_sym, depends_on: depends_on, **rest}]
        end
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
          raise ValidationError, "Node #{to} depends on unknown node #{from}" unless graph.node?(from)
          graph.add_edge(from, to, **metadata)
        end

        Definition.new(graph: graph, registry: registry)
      end

      def self.validate_type!(name, type, valid_types: Steps.types)
        return if valid_types.include?(type)

        if Steps.types.include?(type) && !valid_types.include?(type)
          raise ValidationError, "Node '#{name}' has type '#{type}' which is not supported in YAML. Use from_hash for programmatic step types."
        end

        raise ValidationError, "Node '#{name}' has invalid type '#{type}'. Valid: #{valid_types.join(", ")}"
      end

      def self.parse_depends_on(raw)
        Array(raw).map do |dep|
          case dep
          when Hash
            dep.transform_keys(&:to_sym).tap { |h| h[:from] = h[:from].to_sym }
          when String, Symbol
            {from: dep.to_sym}
          else
            raise ValidationError, "Invalid depends_on entry: #{dep.inspect}"
          end
        end
      end

      private_class_method :build_definition, :validate_type!, :parse_depends_on, :normalize_entries
    end
  end
end
