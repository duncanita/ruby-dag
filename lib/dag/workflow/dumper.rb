# frozen_string_literal: true

require "yaml"

module DAG
  module Workflow
    class Dumper
      NON_SERIALIZABLE_TYPES = %i[ruby].freeze

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
        step.config.each { |k, v| node[k.to_s] = v }
        deps = @graph.predecessors(name).to_a.sort
        node["depends_on"] = deps.map(&:to_s) unless deps.empty?
        node
      end
    end
  end
end
