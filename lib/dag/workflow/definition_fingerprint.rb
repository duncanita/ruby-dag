# frozen_string_literal: true

require "digest"

module DAG
  module Workflow
    class DefinitionFingerprint
      class << self
        def for(definition, root_input: {})
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
          data[:root_input] = normalize_root_input(root_input) unless root_input.empty?

          Digest::SHA256.hexdigest(canonical_encode(data))
        end

        private

        # Deterministic, alias-free serializer. Hashes are key-sorted; equal
        # subtrees always serialize identically regardless of object identity,
        # so two structurally-equivalent inputs cannot produce different
        # digests because of shared-vs-fresh references in the source tree.
        def canonical_encode(value)
          case value
          when Hash
            "{" + value.sort_by { |k, _| k.to_s }.map { |k, v| "#{canonical_encode(k)}=>#{canonical_encode(v)}" }.join(",") + "}"
          when Array
            "[" + value.map { |v| canonical_encode(v) }.join(",") + "]"
          when Symbol
            ":#{value}"
          when String
            value.dump
          when Integer, Float, TrueClass, FalseClass, NilClass
            value.inspect
          else
            raise SerializationError, "non-canonical fingerprint value: #{value.inspect} (#{value.class})"
          end
        end

        def normalize_root_input(root_input)
          root_input.each_with_object({}) do |(key, nested), hash|
            hash[key.to_sym] = normalize_root_input_value(nested)
          end.sort_by { |key, _| key.to_s }.to_h
        end

        def normalize_root_input_value(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested), hash|
              hash[key] = normalize_root_input_value(nested)
            end.sort_by { |key, _| root_input_key_sort_token(key) }.to_h
          when Array
            value.map { |nested| normalize_root_input_value(nested) }
          else
            value
          end
        end

        def root_input_key_sort_token(key)
          [key.class.name, key.inspect]
        end

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
          resume_key = step.config[:resume_key]

          raise ValidationError, "Step #{step.name} (type: :sub_workflow) requires resume_key when durable execution is enabled" if blank?(resume_key)

          child_definition = SubWorkflowSupport.resolve_definition(step, source_path: source_path)

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

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end
    end
  end
end
