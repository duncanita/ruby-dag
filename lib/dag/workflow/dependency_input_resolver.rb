# frozen_string_literal: true

module DAG
  module Workflow
    class DependencyInputResolver
      class ResolutionError < StandardError
        def initialize(message, **fields)
          super(message)
          fields.each { |key, value| instance_variable_set(:"@#{key}", value) }
        end
      end

      class MissingVersionError < ResolutionError
        attr_reader :dependency_name, :version
      end

      class MissingExecutionStoreError < ResolutionError
        attr_reader :dependency_name, :version
      end

      class MissingCrossWorkflowResolverError < ResolutionError
        attr_reader :workflow_id, :node_name, :version
      end

      class WaitingForDependencyError < ResolutionError
        attr_reader :workflow_id, :node_name, :version
      end

      class ResolverError < ResolutionError
        attr_reader :workflow_id, :node_name, :version
      end

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

      def input_keys_for(name:, step:)
        keys = @root_input.keys
        keys += local_dependencies_for(name).map(&:input_key)
        keys += external_dependencies_for(step).map(&:input_key)
        keys.map(&:to_sym).uniq.sort
      end

      def condition_context_for(name:, step:, outputs:, statuses:, condition: nil)
        dependency_context = root_condition_context.merge(local_condition_context(name, outputs, statuses))

        referenced_external_dependencies(step, condition).each do |dependency|
          dependency_context[dependency.input_key] = {
            value: resolve_external_dependency_value(dependency),
            status: :success
          }
        end

        dependency_context
      end

      def callable_input_for(name:, step:, outputs:, statuses:)
        LazyCallableInput.new(
          base_values: root_callable_values.merge(local_callable_values(name, outputs, statuses)),
          external_loaders: external_dependencies_for(step).to_h do |dependency|
            [dependency.input_key, -> { resolve_external_dependency_value(dependency) }]
          end
        )
      end

      private

      LocalDependency = Data.define(:name, :input_key, :version, :node_path)
      ExternalDependency = Data.define(:workflow_id, :node_name, :input_key, :version)

      class LazyCallableInput
        def initialize(base_values:, external_loaders:)
          @base_values = base_values.transform_keys(&:to_sym)
          @external_loaders = external_loaders.transform_keys(&:to_sym)
          @resolved_values = {}
        end

        def [](key)
          sym = key.to_sym
          return @base_values[sym] if @base_values.key?(sym)
          return @resolved_values[sym] if @resolved_values.key?(sym)
          return @resolved_values[sym] = @external_loaders.fetch(sym).call if @external_loaders.key?(sym)

          nil
        end

        def fetch(key, *default, &block)
          sym = key.to_sym
          return self[sym] if key?(sym)
          return yield(sym) if block
          return default.first unless default.empty?

          raise KeyError, "key not found: #{sym.inspect}"
        end

        def key?(key)
          sym = key.to_sym
          @base_values.key?(sym) || @resolved_values.key?(sym) || @external_loaders.key?(sym)
        end
        alias_method :include?, :key?
        alias_method :has_key?, :key?

        def keys
          (@base_values.keys + @external_loaders.keys).uniq
        end

        def each
          return enum_for(:each) unless block_given?

          keys.each do |key|
            yield key, self[key]
          end
        end

        def to_h
          keys.each_with_object({}) do |key, memo|
            memo[key] = self[key]
          end
        end

        def transform_values(&block)
          to_h.transform_values(&block)
        end
      end

      def local_dependencies_for(name)
        @local_dependencies ||= {}
        @local_dependencies[name] ||= @graph.each_predecessor(name).sort.map do |dependency_name|
          metadata = @graph.edge_metadata(dependency_name, name)
          LocalDependency.new(
            name: dependency_name,
            input_key: (metadata[:as] || dependency_name).to_sym,
            version: metadata.fetch(:version, :latest),
            node_path: node_path_for(dependency_name)
          )
        end
      end

      def external_dependencies_for(step)
        @external_dependencies ||= {}
        @external_dependencies[step.name] ||= Array(step.config[:external_dependencies]).map do |dependency|
          ExternalDependency.new(
            workflow_id: dependency.fetch(:workflow_id),
            node_name: dependency.fetch(:node),
            input_key: (dependency[:as] || dependency[:node]).to_sym,
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
          unless stored
            raise MissingVersionError.new(
              missing_version_message(dependency.name, dependency.version),
              dependency_name: dependency.name,
              version: dependency.version
            )
          end

          stored[:result].value
        end
      end

      def root_condition_context
        @root_input.transform_values { |value| {value: value, status: :success} }
      end

      def local_condition_context(name, outputs, statuses)
        local_dependencies_for(name).to_h do |dependency|
          status = (dependency.version == :latest) ? statuses.fetch(dependency.name) : :success
          [dependency.input_key, {
            value: resolve_local_dependency_value(dependency, outputs),
            status: status
          }]
        end
      end

      def root_callable_values
        @root_input.dup
      end

      def local_callable_values(name, outputs, statuses)
        local_condition_context(name, outputs, statuses).transform_values { |entry| entry[:value] }
      end

      def referenced_external_dependencies(step, condition)
        dependencies = external_dependencies_for(step)
        return [] if condition.nil? || Condition.callable?(condition)

        referenced_keys = extract_condition_dependency_keys(condition)
        dependencies.select { |dependency| referenced_keys.include?(dependency.input_key) }
      end

      def extract_condition_dependency_keys(condition)
        Condition.referenced_from_keys(condition)
      end

      def resolve_external_dependency_value(dependency)
        unless @cross_workflow_resolver
          raise MissingCrossWorkflowResolverError.new(
            "external dependency #{dependency.workflow_id}.#{dependency.node_name} requires cross_workflow_resolver",
            workflow_id: dependency.workflow_id,
            node_name: dependency.node_name,
            version: dependency.version
          )
        end

        resolved = invoke_cross_workflow_resolver(dependency)
        if resolved.nil?
          raise WaitingForDependencyError.new(
            waiting_dependency_message(dependency),
            workflow_id: dependency.workflow_id,
            node_name: dependency.node_name,
            version: dependency.version
          )
        end

        normalize_external_value(resolved, dependency)
      rescue WaitingForDependencyError, MissingCrossWorkflowResolverError
        raise
      rescue => e
        raise ResolverError.new(
          "cross-workflow resolver failed for #{dependency.workflow_id}.#{dependency.node_name}: #{e.message}",
          workflow_id: dependency.workflow_id,
          node_name: dependency.node_name,
          version: dependency.version
        )
      end

      def invoke_cross_workflow_resolver(dependency)
        if accepts_keyword_arguments?
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

      def node_path_for(dependency_name)
        @node_path_prefix + [dependency_name.to_sym]
      end

      def ensure_execution_store!(dependency_name, version)
        return if @execution_store && @workflow_id

        raise MissingExecutionStoreError.new(
          "dependency #{dependency_name} requests version #{version.inspect} but versioned inputs require execution_store and workflow_id",
          dependency_name: dependency_name,
          version: version
        )
      end

      def missing_version_message(dependency_name, version)
        "dependency #{dependency_name} requested missing version #{version.inspect}"
      end

      def waiting_dependency_message(dependency)
        "external dependency #{dependency.workflow_id}.#{dependency.node_name} version #{dependency.version.inspect} is unavailable"
      end

      def accepts_keyword_arguments?
        callable_parameters.any? { |kind, _name| %i[keyrest key keyreq].include?(kind) }
      end

      def callable_parameters
        @callable_parameters ||= if @cross_workflow_resolver.respond_to?(:parameters)
          @cross_workflow_resolver.parameters
        else
          @cross_workflow_resolver.method(:call).parameters
        end
      end
    end
  end
end
