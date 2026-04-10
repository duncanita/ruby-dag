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

      # Symbols permitted so step configs with `:symbol` values round-trip
      # through Dumper. Nothing else — keep the surface tight.
      def self.from_yaml(yaml_string)
        data = YAML.safe_load(yaml_string, permitted_classes: [Symbol])
        raise ValidationError, "YAML must contain a 'nodes' mapping" unless data.is_a?(Hash) && data["nodes"].is_a?(Hash)

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
          raise ValidationError, "Node '#{name}' must be a mapping, got #{opts.inspect}" unless opts.is_a?(Hash)
          opts = opts.dup
          type = opts.delete(type_key)
          raise ValidationError, "Node '#{name}' missing 'type'" if type.nil? || type.to_s.empty?
          validate_type!(name, type.to_sym, valid_types: valid_types)

          depends_on = parse_depends_on(opts.delete(depends_key))
          rest = string_keys ? opts.transform_keys(&:to_sym) : opts
          [name.to_sym, {type: type.to_sym, depends_on: depends_on, **rest}]
        end
      end

      # Two-pass build: first pass adds every node and registers its step;
      # second pass adds the edges. The split exists because `Graph#add_edge`
      # validates that BOTH endpoints already exist, and YAML files routinely
      # declare nodes in any order — a node `consumer` whose `depends_on` lists
      # `producer` may appear before `producer` is declared. Adding nodes first
      # and edges second makes declaration order irrelevant; the resulting
      # error for a typoed dependency is also clearer (`unknown node X`) than
      # the bare `UnknownNodeError` you'd get from edge insertion mid-pass.
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
            dep.transform_keys(&:to_sym).tap do |h|
              raise ValidationError, "depends_on entry #{dep.inspect} missing required 'from' key" unless h.key?(:from)
              h[:from] = h[:from].to_sym
            end
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
