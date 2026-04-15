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
                fingerprint: fingerprint_step(step)
              }
            end
          }

          Digest::SHA256.hexdigest(YAML.dump(data))
        end

        private

        def fingerprint_step(step)
          if Steps.yaml_types.include?(step.type)
            normalize(step.config)
          elsif step.type == :ruby
            resume_key = step.config[:resume_key]
            raise ValidationError, "Step #{step.name} (type: :ruby) requires resume_key when durable execution is enabled" if blank?(resume_key)

            {resume_key: resume_key.to_s}
          else
            raise ValidationError,
              "Step #{step.name} (type: #{step.type}) cannot be fingerprinted for durable execution"
          end
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

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end
    end
  end
end
