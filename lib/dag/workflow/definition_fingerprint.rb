# frozen_string_literal: true

require "digest"
require "yaml"

module DAG
  module Workflow
    class DefinitionFingerprint
      class << self
        def for(definition)
          data = {
            graph: definition.graph.to_h,
            steps: definition.graph.topological_sort.map do |name|
              step = definition.registry[name]
              {
                name: step.name,
                type: step.type,
                fingerprint: fingerprint_step(step, source_path: definition.source_path)
              }
            end
          }

          Digest::SHA256.hexdigest(YAML.dump(data))
        end

        private

        def fingerprint_step(step, source_path: nil)
          if step.type == :sub_workflow
            fingerprint_sub_workflow_step(step, source_path: source_path)
          elsif step.type == :ruby
            resume_key = step.config[:resume_key]
            raise ValidationError, "Step #{step.name} (type: :ruby) requires resume_key when durable execution is enabled" if blank?(resume_key)

            {resume_key: resume_key.to_s}
          elsif Steps.yaml_types.include?(step.type)
            normalize(step.config)
          else
            raise ValidationError,
              "Step #{step.name} (type: #{step.type}) cannot be fingerprinted for durable execution"
          end
        end

        def fingerprint_sub_workflow_step(step, source_path: nil)
          definition = step.config[:definition]
          definition_path = step.config[:definition_path]
          resume_key = step.config[:resume_key]

          raise ValidationError, "Step #{step.name} (type: :sub_workflow) requires resume_key when durable execution is enabled" if blank?(resume_key)

          child_definition = if definition.is_a?(Definition) && blank?(definition_path)
            definition
          elsif definition.nil? && !blank?(definition_path)
            Loader.from_file(resolve_path(definition_path, source_path: source_path))
          else
            raise ValidationError, "Step #{step.name} (type: :sub_workflow) must define exactly one of definition or definition_path"
          end

          {
            resume_key: resume_key.to_s,
            input_mapping: normalize(step.config[:input_mapping] || {}),
            output_key: step.config[:output_key]&.to_sym,
            definition_fingerprint: self.for(child_definition)
          }
        end

        def normalize(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested), hash|
              hash[key.to_sym] = normalize(nested)
            end.sort_by { |key, _| key.to_s }.to_h
          when Array
            value.map { |nested| normalize(nested) }
          else
            value
          end
        end

        def resolve_path(path, source_path: nil)
          return path if Pathname.new(path).absolute?

          base_dir = source_path && File.dirname(source_path)
          File.expand_path(path, base_dir || Dir.pwd)
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end
    end
  end
end
