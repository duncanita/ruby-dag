# frozen_string_literal: true

require "yaml"

module DAG
  module Workflow
    class Dumper
      NON_SERIALIZABLE_TYPES = %i[ruby].freeze
      # Output keys owned by the YAML node itself; a colliding config key
      # would silently overwrite them.
      RESERVED_YAML_KEYS = %w[type depends_on run_if].freeze

      def self.to_yaml(definition)
        new(definition).dump
      end

      def self.to_file(definition, path)
        File.write(path, to_yaml(definition))
      end

      private_class_method :new

      def initialize(definition)
        @graph = definition.graph
        @registry = definition.registry
      end

      def dump
        Validator.validate!(@graph, @registry)
        data = {}
        @graph.topological_sort.each do |name|
          step = @registry[name]
          raise SerializationError, "Step #{name} (type: #{step.type}) is not YAML-serializable" if NON_SERIALIZABLE_TYPES.include?(step.type)

          data[name.to_s] = build_step(name, step)
        end
        {"nodes" => data}.to_yaml
      end

      private

      def build_step(name, step)
        node = {"type" => step.type.to_s}
        if step.config.key?(:run_if) && !step.config[:run_if].nil?
          node["run_if"] = Condition.dumpable(step.config[:run_if])
        end
        step.config.each do |k, v|
          key = k.to_s
          next if key == "run_if"
          if RESERVED_YAML_KEYS.include?(key)
            raise SerializationError,
              "Step #{name} has config key '#{key}' which collides with a " \
              "reserved YAML key (#{RESERVED_YAML_KEYS.join(", ")}). " \
              "Rename the config key before dumping."
          end
          node[key] = v
        end
        deps = @graph.predecessors(name).to_a.sort
        unless deps.empty?
          node["depends_on"] = deps.map { |dep|
            meta = @graph.edge_metadata(dep, name)
            if meta.empty?
              dep.to_s
            else
              {"from" => dep.to_s}.merge(meta.transform_keys(&:to_s))
            end
          }
        end
        node
      end
    end
  end
end
