# frozen_string_literal: true

module DAG
  module Workflow
    class DependencyInputResolver
      MissingVersionError = Class.new(StandardError)
      MissingExecutionStoreError = Class.new(StandardError)
      WaitingForDependencyError = Class.new(StandardError)
      ResolverError = Class.new(StandardError)

      def initialize(graph:, execution_store:, workflow_id:, cross_workflow_resolver: nil, root_input: {}, node_path_prefix: [])
        @graph = graph
        @execution_store = execution_store
        @workflow_id = workflow_id
        @cross_workflow_resolver = cross_workflow_resolver
        @root_input = root_input.transform_keys(&:to_sym).freeze
        @node_path_prefix = Array(node_path_prefix).map(&:to_sym).freeze
      end

      def resolve(name:, step:, outputs:)
        input = @root_input.dup

        local_dependencies_for(name).each do |dependency|
          input[dependency.input_key] = resolve_local_dependency_value(dependency, outputs)
        end

        external_dependencies_for(step).each do |dependency|
          input[dependency.input_key] = resolve_external_dependency_value(dependency)
        end

        input
      end

      private

      LocalDependency = Data.define(:name, :input_key, :version, :node_path)
      ExternalDependency = Data.define(:workflow_id, :node_name, :input_key, :version)

      def local_dependencies_for(name)
        @graph.each_predecessor(name).sort.map do |dependency_name|
          metadata = @graph.edge_metadata(dependency_name, name)
          LocalDependency.new(
            name: dependency_name,
            input_key: effective_input_key(metadata[:as] || dependency_name),
            version: metadata.fetch(:version, :latest),
            node_path: node_path_for(dependency_name)
          )
        end
      end

      def external_dependencies_for(step)
        Array(step.config[:external_dependencies]).map do |dependency|
          ExternalDependency.new(
            workflow_id: dependency.fetch(:workflow_id),
            node_name: dependency.fetch(:node),
            input_key: effective_input_key(dependency[:as] || dependency[:node]),
            version: dependency.fetch(:version, :latest)
          )
        end
      end

      def resolve_local_dependency_value(dependency, outputs)
        return outputs.fetch(dependency.name).value if dependency.version == :latest

        ensure_execution_store!(dependency.name, dependency.version)

        if dependency.version == :all
          Array(@execution_store.load_output(
            workflow_id: @workflow_id,
            node_path: dependency.node_path,
            version: :all
          )).map { |entry| entry[:result].value }
        else
          stored = @execution_store.load_output(
            workflow_id: @workflow_id,
            node_path: dependency.node_path,
            version: dependency.version
          )
          raise MissingVersionError, missing_version_message(dependency.name, dependency.version) unless stored

          stored[:result].value
        end
      end

      def resolve_external_dependency_value(dependency)
        unless @cross_workflow_resolver
          raise MissingExecutionStoreError,
            "external dependency #{dependency.workflow_id}.#{dependency.node_name} requires cross_workflow_resolver"
        end

        resolved = invoke_cross_workflow_resolver(dependency)
        raise WaitingForDependencyError, waiting_dependency_message(dependency) if resolved.nil?

        normalize_external_value(resolved, dependency)
      rescue WaitingForDependencyError
        raise
      rescue => e
        raise ResolverError, "cross-workflow resolver failed for #{dependency.workflow_id}.#{dependency.node_name}: #{e.message}"
      end

      def invoke_cross_workflow_resolver(dependency)
        call_method = @cross_workflow_resolver.method(:call)
        if accepts_keyword_arguments?(call_method)
          @cross_workflow_resolver.call(
            workflow_id: dependency.workflow_id,
            node_name: dependency.node_name,
            version: dependency.version
          )
        else
          @cross_workflow_resolver.call(dependency.workflow_id, dependency.node_name, dependency.version)
        end
      end

      def normalize_external_value(resolved, dependency)
        if dependency.version == :all
          Array(resolved).map { |value| normalize_external_scalar(value) }
        else
          normalize_external_scalar(resolved)
        end
      end

      def normalize_external_scalar(value)
        if value.is_a?(Hash) && value.key?(:result)
          return value[:result].value if value[:result].is_a?(Success)
          return value[:result]
        end

        return value.value if value.is_a?(Success)

        value
      end

      def effective_input_key(value)
        value.to_sym
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

      def waiting_dependency_message(dependency)
        "external dependency #{dependency.workflow_id}.#{dependency.node_name} version #{dependency.version.inspect} is unavailable"
      end

      def accepts_keyword_arguments?(call_method)
        call_method.parameters.any? { |kind, _name| kind == :keyrest } ||
          call_method.parameters.any? { |kind, _name| [:key, :keyreq].include?(kind) }
      end
    end
  end
end
