# frozen_string_literal: true

require "yaml"

module DAG
  # Loads a DAG from a YAML file.
  #
  #   graph = DAG::Loader.from_file("workflow.yml")
  #   graph = DAG::Loader.from_yaml(yaml_string)
  #
  # YAML format:
  #
  #   name: my-workflow
  #   nodes:
  #     fetch_data:
  #       type: exec
  #       command: "curl -s https://api.example.com/data"
  #       timeout: 10
  #
  #     process:
  #       type: script
  #       path: "scripts/process.rb"
  #       depends_on:
  #         - fetch_data
  #
  #     write_result:
  #       type: file_write
  #       path: "output.json"
  #       depends_on:
  #         - process

  class Loader
    VALID_TYPES = %w[exec script file_read file_write ruby llm].freeze

    def self.from_file(path)
      raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

      from_yaml(File.read(path))
    end

    def self.from_yaml(yaml_string)
      data = YAML.safe_load(yaml_string, permitted_classes: [Symbol])
      raise ArgumentError, "YAML must contain 'nodes' key" unless data&.key?("nodes")

      graph = Graph.new

      data["nodes"].each do |name, config|
        type = config.delete("type") || raise(ArgumentError, "Node '#{name}' missing 'type'")
        unless VALID_TYPES.include?(type)
          raise ArgumentError, "Node '#{name}' has invalid type '#{type}'. Valid: #{VALID_TYPES.join(', ')}"
        end

        depends_on = Array(config.delete("depends_on"))

        # Convert string keys to symbols for config
        node_config = config.transform_keys(&:to_sym)

        graph.add_node(
          name: name,
          type: type,
          depends_on: depends_on,
          **node_config
        )
      end

      graph.validate!
      graph
    end
  end
end
