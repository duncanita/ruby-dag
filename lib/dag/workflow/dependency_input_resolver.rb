# frozen_string_literal: true

module DAG
  module Workflow
    class DependencyInputResolver
      MissingVersionError = Class.new(StandardError)
      MissingExecutionStoreError = Class.new(StandardError)

      def initialize(graph:, execution_store:, workflow_id:, root_input: {}, node_path_prefix: [])
        @graph = graph
        @execution_store = execution_store
        @workflow_id = workflow_id
        @root_input = root_input.transform_keys(&:to_sym).freeze
        @node_path_prefix = Array(node_path_prefix).map(&:to_sym).freeze
      end

      def resolve(name:, outputs:)
        input = @root_input.dup

        @graph.each_predecessor(name).sort.each do |dependency_name|
          metadata = @graph.edge_metadata(dependency_name, name)
          input[effective_input_key(dependency_name, metadata)] = resolve_dependency_value(dependency_name, metadata, outputs)
        end

        input
      end

      private

      def resolve_dependency_value(dependency_name, metadata, outputs)
        version = metadata.fetch(:version, :latest)
        return outputs.fetch(dependency_name).value if version == :latest

        ensure_execution_store!(dependency_name, version)

        if version == :all
          Array(@execution_store.load_output(
            workflow_id: @workflow_id,
            node_path: node_path_for(dependency_name),
            version: :all
          )).map { |entry| entry[:result].value }
        else
          stored = @execution_store.load_output(
            workflow_id: @workflow_id,
            node_path: node_path_for(dependency_name),
            version: version
          )
          raise MissingVersionError, missing_version_message(dependency_name, version) unless stored

          stored[:result].value
        end
      end

      def effective_input_key(dependency_name, metadata)
        (metadata[:as] || dependency_name).to_sym
      end

      def node_path_for(dependency_name)
        @node_path_prefix + [dependency_name.to_sym]
      end

      def ensure_execution_store!(dependency_name, version)
        return if @execution_store && @workflow_id

        raise MissingExecutionStoreError,
          "dependency #{dependency_name} requests version #{version.inspect} but versioned inputs require execution_store and workflow_id"
      end

      def missing_version_message(dependency_name, version)
        "dependency #{dependency_name} requested missing version #{version.inspect}"
      end
    end
  end
end
