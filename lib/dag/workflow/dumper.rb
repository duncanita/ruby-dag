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
          validate_serializable_step!(name, step)

          data[name.to_s] = build_step(name, step)
        end
        {"nodes" => data}.to_yaml
      end

      private

      def validate_serializable_step!(name, step)
        raise SerializationError, "Step #{name} (type: #{step.type}) is not YAML-serializable" if NON_SERIALIZABLE_TYPES.include?(step.type)

        return unless step.type == :sub_workflow

        SubWorkflowSupport.validate_yaml_serializable!(step, node_name: name)
      end

      def build_step(name, step)
        node = {"type" => step.type.to_s}
        if step.config.key?(:run_if) && !step.config[:run_if].nil?
          node["run_if"] = Condition.dumpable(step.config[:run_if])
        end
        step.config.each do |k, v|
          key = k.to_s
          next if %w[run_if external_dependencies].include?(key)
          if RESERVED_YAML_KEYS.include?(key)
            raise SerializationError,
              "Step #{name} has config key '#{key}' which collides with a " \
              "reserved YAML key (#{RESERVED_YAML_KEYS.join(", ")}). " \
              "Rename the config key before dumping."
          end
          node[key] = dumpable_config_value(k, v)
        end
        depends_on = local_dependency_descriptors(name) + external_dependency_descriptors(step)
        node["depends_on"] = depends_on unless depends_on.empty?
        node
      end

      def local_dependency_descriptors(name)
        @graph.predecessors(name).to_a.sort.map do |dep|
          meta = @graph.edge_metadata(dep, name)
          if meta.empty?
            dep.to_s
          else
            {"from" => dep.to_s}.merge(meta.transform_keys(&:to_s))
          end
        end
      end

      def external_dependency_descriptors(step)
        Array(step.config[:external_dependencies]).map do |dependency|
          {
            "workflow" => dependency.fetch(:workflow_id).to_s,
            "node" => dependency.fetch(:node).to_s
          }.merge(dependency.except(:workflow_id, :node).transform_keys(&:to_s))
        end
      end

      def dumpable_config_value(key, value)
        case key.to_sym
        when :schedule
          dumpable_schedule(value)
        else
          value
        end
      end

      def dumpable_schedule(value)
        raise SerializationError, "schedule must be a mapping to dump as YAML" unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, nested), dumped|
          dumped[key.to_s] = dumpable_schedule_value(nested)
        end
      end

      def dumpable_schedule_value(value)
        case value
        when Time
          value.utc.iso8601
        else
          value
        end
      end
    end
  end
end
