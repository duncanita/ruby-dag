# frozen_string_literal: true

require "yaml"

module DAG
  # Loads a DAG from YAML.
  #
  #   graph = DAG::Loader.from_file("workflow.yml")
  #   graph = DAG::Loader.from_yaml(yaml_string)

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
        .then { |data| build_graph(data) }
    end

    def self.validate_structure(data)
      raise ArgumentError, "YAML must contain 'nodes' key" unless data&.key?("nodes")

      data
    end

    def self.build_graph(data)
      data["nodes"]
        .each_with_object(Graph.new) { |(name, config), graph| add_node_from_yaml(graph, name, config.dup) }
        .validate!
    end

    def self.add_node_from_yaml(graph, name, config)
      type = config.delete("type") || raise(ArgumentError, "Node '#{name}' missing 'type'")
      validate_type!(name, type)

      depends_on = Array(config.delete("depends_on"))

      graph.add_node(name: name, type: type, depends_on: depends_on, **config.transform_keys(&:to_sym))
    end

    def self.validate_type!(name, type)
      return if VALID_TYPES.include?(type)

      raise ArgumentError, "Node '#{name}' has invalid type '#{type}'. Valid: #{VALID_TYPES.join(', ')}"
    end

    private_class_method :validate_structure, :build_graph, :add_node_from_yaml, :validate_type!
  end
end
