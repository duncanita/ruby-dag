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
        expanded_path = File.expand_path(path)
        from_yaml(File.read(expanded_path), source_path: expanded_path)
      rescue Errno::ENOENT
        raise ArgumentError, "File not found: #{path}"
      end

      # Symbols permitted so step configs with `:symbol` values round-trip
      # through Dumper. Nothing else — keep the surface tight.
      def self.from_yaml(yaml_string, source_path: nil)
        data = YAML.safe_load(yaml_string, permitted_classes: [Symbol])
        raise ValidationError, "YAML must contain a 'nodes' mapping" unless data.is_a?(Hash) && data["nodes"].is_a?(Hash)

        build_definition(normalize_entries(data["nodes"], string_keys: true), source_path: source_path)
      end

      def self.from_hash(**node_defs)
        build_definition(normalize_entries(node_defs, string_keys: false), source_path: nil)
      end

      def self.normalize_entries(node_defs, string_keys:)
        type_key = string_keys ? "type" : :type
        depends_key = string_keys ? "depends_on" : :depends_on
        valid_types = string_keys ? Steps.yaml_types : Steps.types

        node_defs.map do |name, opts|
          node_name = coerce_symbol!(name, context: "Node name")
          raise ValidationError, "Node '#{node_name}' must be a mapping, got #{opts.inspect}" unless opts.is_a?(Hash)
          opts = opts.dup
          type = opts.delete(type_key)
          raise ValidationError, "Node '#{node_name}' missing 'type'" if type.nil? || type.to_s.empty?
          type_sym = type.to_sym
          validate_type!(node_name, type_sym, valid_types: valid_types)

          depends_on = parse_depends_on(opts.delete(depends_key))
          rest = normalize_config_keys(opts, node_name: node_name)
          if string_keys && rest.key?(:run_if) && rest[:run_if].nil?
            raise ValidationError, "Node '#{node_name}' has a blank run_if — remove it or provide a condition"
          end
          [node_name, {type: type_sym, depends_on: depends_on, **rest}]
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
      def self.build_definition(entries, source_path: nil)
        graph = Graph.new
        registry = Registry.new
        deferred_edges = []

        entries.each do |name, opts|
          opts = opts.dup
          depends_on = opts.delete(:depends_on)
          type = opts.delete(:type)
          external_dependencies = []

          depends_on.each do |dep|
            if dep.key?(:from)
              deferred_edges << dep.merge(to: name)
            else
              external_dependency = dep.dup
              external_dependency[:workflow_id] = external_dependency.delete(:workflow)
              external_dependencies << external_dependency
            end
          end

          opts[:external_dependencies] = external_dependencies unless external_dependencies.empty?
          graph.add_node(name)
          registry.register(Step.new(name: name, type: type, **opts))
        end

        deferred_edges.each do |edge|
          from = edge[:from]
          to = edge[:to]
          metadata = edge.except(:from, :to)
          raise ValidationError, "Node #{to} depends on unknown node #{from}" unless graph.node?(from)
          graph.add_edge(from, to, **metadata)
        end

        Validator.validate!(graph, registry)
        Definition.new(graph: graph, registry: registry, source_path: source_path)
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
            dep.each_with_object({}) do |(key, value), h|
              key_sym = coerce_symbol!(key, context: "depends_on key in #{dep.inspect}")
              h[key_sym] = normalize_depends_on_value(key_sym, value, dep: dep)
            end.tap do |h|
              validate_depends_on_descriptor!(h, dep)
            end
          when String, Symbol
            {from: dep.to_sym}
          else
            raise ValidationError, "Invalid depends_on entry: #{dep.inspect}"
          end
        end
      end

      def self.normalize_config_keys(opts, node_name:)
        opts.each_with_object({}) do |(key, value), h|
          key_sym = coerce_symbol!(key, context: "config key for node '#{node_name}'")
          h[key_sym] = normalize_config_value(key_sym, value, node_name: node_name)
        end
      end

      def self.normalize_depends_on_value(key, value, dep:)
        case key
        when :from, :node
          coerce_symbol!(value, context: "depends_on :#{key} in #{dep.inspect}")
        when :workflow
          value.to_s
        when :version
          normalize_version_selector(value, dep: dep)
        when :as
          coerce_symbol!(value, context: "depends_on :as in #{dep.inspect}")
        else
          value
        end
      end

      def self.normalize_version_selector(value, dep:)
        return value if value.is_a?(Integer)
        return value if value == :latest || value == :all

        string = value.to_s
        return string.to_sym if %w[latest all].include?(string)

        Integer(string, exception: false) || value
      end

      def self.validate_depends_on_descriptor!(descriptor, raw_dep)
        if descriptor.key?(:from)
          raise ValidationError, "depends_on entry #{raw_dep.inspect} cannot mix 'from' with cross-workflow keys" if descriptor.key?(:workflow) || descriptor.key?(:node)

          return descriptor
        end

        return descriptor if descriptor.key?(:workflow) && descriptor.key?(:node)

        raise ValidationError, "depends_on entry #{raw_dep.inspect} must provide either 'from' or both 'workflow' and 'node'"
      end

      def self.normalize_config_value(key, value, node_name:)
        case key
        when :schedule
          normalize_schedule_config(value, node_name: node_name)
        else
          value
        end
      end

      def self.normalize_schedule_config(value, node_name:)
        raise ValidationError, "Node '#{node_name}' schedule must be a mapping, got #{value.inspect}" unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, nested), h|
          h[coerce_symbol!(key, context: "schedule key for node '#{node_name}'")] = nested
        end
      end

      def self.coerce_symbol!(value, context:)
        value.to_sym
      rescue NoMethodError, TypeError
        raise ValidationError, "#{context} must be symbolizable, got #{value.inspect}"
      end

      private_class_method :build_definition, :validate_type!, :parse_depends_on, :normalize_entries,
        :normalize_config_keys, :normalize_depends_on_value, :normalize_version_selector,
        :validate_depends_on_descriptor!, :normalize_config_value, :normalize_schedule_config, :coerce_symbol!
    end
  end
end
