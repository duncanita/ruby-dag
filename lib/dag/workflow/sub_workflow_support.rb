# frozen_string_literal: true

module DAG
  module Workflow
    class SubWorkflowSupport
      class << self
        def validate(step, node_name: step.name)
          return [] unless step.type == :sub_workflow

          definition = step.config[:definition]
          definition_path = step.config[:definition_path]
          errors = []

          unless exactly_one_source?(definition, definition_path)
            errors << "Node '#{node_name}' type 'sub_workflow' must define exactly one of definition or definition_path"
          end

          if step.config.key?(:definition_path) && !definition_path.nil? && !definition_path.is_a?(String)
            errors << "Node '#{node_name}' definition_path must be a String"
          end

          errors
        end

        def validate_yaml_serializable!(step, node_name: step.name)
          definition = step.config[:definition]
          definition_path = step.config[:definition_path]
          return if definition.nil? && present?(definition_path)

          raise SerializationError,
            "Step #{node_name} (type: :sub_workflow) is YAML-serializable only when it uses definition_path"
        end

        def resolve_definition(step, source_path: nil)
          definition = step.config[:definition]
          definition_path = step.config[:definition_path]

          if definition.is_a?(Definition) && blank?(definition_path)
            return definition
          end

          if definition.nil? && present?(definition_path)
            return Loader.from_file(resolve_path(definition_path, source_path: source_path))
          end

          raise ValidationError,
            "sub_workflow step #{step.name} must define exactly one of definition or definition_path"
        end

        def resolve_path(path, source_path: nil)
          return path if Pathname.new(path).absolute?

          base_dir = source_path && File.dirname(source_path)
          File.expand_path(path, base_dir || Dir.pwd)
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end

        def present?(value)
          !blank?(value)
        end

        private

        def exactly_one_source?(definition, definition_path)
          has_definition = definition.is_a?(Definition)
          has_definition_path = present?(definition_path)
          has_definition ^ has_definition_path
        end
      end
    end
  end
end
