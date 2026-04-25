# frozen_string_literal: true

module DAG
  module Workflow
    ValidationReport = Data.define(:errors) do
      def initialize(errors:)
        super(errors: errors.freeze)
      end

      def valid? = errors.empty?
    end

    class Validator
      def self.validate(graph, registry)
        errors = []

        graph.each_node do |node|
          next unless registry.key?(node)

          step = registry[node]
          errors.concat(Condition.validate(
            step.config[:run_if],
            node_name: node,
            graph: graph,
            allowed_inputs: allowed_condition_inputs(graph, step, node_name: node)
          ))
          errors.concat(validate_dependency_inputs(graph, step, node_name: node))
          errors.concat(validate_retry(step, node_name: node))
          errors.concat(validate_emit_events(step, node_name: node))
          errors.concat(validate_sub_workflow(step, node_name: node)) if step.type == :sub_workflow
        end

        ValidationReport.new(errors: errors)
      end

      def self.validate!(graph, registry)
        report = validate(graph, registry)
        raise ValidationError, report.errors unless report.valid?

        [graph, registry]
      end

      def self.validate_sub_workflow(step, node_name:)
        SubWorkflowSupport.validate(step, node_name: node_name)
      end

      def self.validate_dependency_inputs(graph, step, node_name:)
        local_errors = graph.each_predecessor(node_name).each_with_object([]) do |dependency_name, errors|
          metadata = graph.edge_metadata(dependency_name, node_name)
          validate_dependency_version(metadata[:version], dependency_name: dependency_name, node_name: node_name, errors: errors) if metadata.key?(:version)
        end

        external_errors = Array(step.config[:external_dependencies]).each_with_object([]) do |dependency, errors|
          validate_external_dependency(dependency, node_name: node_name, errors: errors)
          validate_dependency_version(dependency[:version], dependency_name: "#{dependency[:workflow_id]}.#{dependency[:node]}", node_name: node_name, errors: errors) if dependency.key?(:version)
        end

        local_errors + external_errors + duplicate_effective_input_key_errors(graph, step, node_name: node_name)
      end

      VALID_RETRY_BACKOFFS = %i[fixed linear exponential].freeze

      def self.validate_dependency_version(version, dependency_name:, node_name:, errors:)
        return if version == :latest || version == :all || (version.is_a?(Integer) && version.positive?)

        errors << "Node #{node_name} dependency #{dependency_name} has invalid version #{version.inspect}; expected :latest, :all, or a positive Integer"
      end

      def self.validate_retry(step, node_name:)
        config = step.config[:retry]
        return [] if config.nil?
        return ["Node #{node_name} retry must be a mapping"] unless config.is_a?(Hash)

        cfg = config.transform_keys(&:to_sym)
        errors = []
        unknown = cfg.keys - %i[max_attempts backoff base_delay max_delay retry_on]
        errors << "Node #{node_name} retry has unsupported keys #{unknown.map(&:inspect).join(", ")}" unless unknown.empty?

        validate_retry_max_attempts(cfg[:max_attempts], node_name: node_name, errors: errors) if cfg.key?(:max_attempts)
        validate_retry_backoff(cfg[:backoff], node_name: node_name, errors: errors) if cfg.key?(:backoff)
        validate_retry_delay(cfg[:base_delay], node_name: node_name, key: :base_delay, errors: errors) if cfg.key?(:base_delay)
        validate_retry_delay(cfg[:max_delay], node_name: node_name, key: :max_delay, errors: errors) if cfg.key?(:max_delay)
        validate_retry_max_delay(cfg, node_name: node_name, errors: errors)
        validate_retry_on(cfg[:retry_on], node_name: node_name, errors: errors) if cfg.key?(:retry_on)
        errors
      end

      def self.validate_emit_events(step, node_name:)
        emit_events = step.config[:emit_events]
        return [] if emit_events.nil?

        return ["Node #{node_name} emit_events must be an array of event descriptors"] unless emit_events.is_a?(Array)

        emit_events.each_with_index.each_with_object([]) do |(descriptor, index), errors|
          context = "Node #{node_name} emit_events[#{index}]"

          unless descriptor.is_a?(Hash)
            errors << "#{context} must be a mapping"
            next
          end

          hash = descriptor.transform_keys(&:to_sym)
          unknown = hash.keys - %i[name if payload metadata]
          errors << "#{context} has unsupported keys #{unknown.map(&:inspect).join(", ")}" unless unknown.empty?

          if blank?(hash[:name])
            errors << "#{context} must include :name"
          elsif !symbol_like?(hash[:name])
            errors << "#{context}.name must be a Symbol or String"
          end

          if hash.key?(:if) && !hash[:if].nil? && !callable?(hash[:if])
            errors << "#{context}.if must be callable"
          end

          if hash.key?(:payload) && !hash[:payload].nil? && !callable?(hash[:payload])
            errors << "#{context}.payload must be callable"
          end

          if hash.key?(:metadata) && !hash[:metadata].nil? && !callable?(hash[:metadata])
            errors << "#{context}.metadata must be callable"
          end
        end
      end

      def self.validate_external_dependency(dependency, node_name:, errors:)
        if blank?(dependency[:workflow_id]) || blank?(dependency[:node])
          errors << "Node #{node_name} has invalid external dependency #{dependency.inspect}; expected workflow_id and node"
        end
      end

      def self.allowed_condition_inputs(graph, step, node_name:)
        local_keys = graph.each_predecessor(node_name).map do |dependency_name|
          local_effective_input_key(graph, dependency_name, node_name)
        end
        external_keys = Array(step.config[:external_dependencies]).map do |dependency|
          external_effective_input_key(dependency)
        end
        local_keys + external_keys
      end

      def self.duplicate_effective_input_key_errors(graph, step, node_name:)
        keys = graph.each_predecessor(node_name).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |dependency_name, memo|
          memo[local_effective_input_key(graph, dependency_name, node_name)] << dependency_name
        end

        Array(step.config[:external_dependencies]).each do |dependency|
          keys[external_effective_input_key(dependency)] << "#{dependency[:workflow_id]}.#{dependency[:node]}"
        end

        keys.filter_map do |key, dependencies|
          next unless dependencies.size > 1

          "Node #{node_name} has duplicate effective input key #{key.inspect} from dependencies #{dependencies.sort_by(&:to_s).inspect}"
        end
      end

      def self.local_effective_input_key(graph, dependency_name, node_name)
        metadata = graph.edge_metadata(dependency_name, node_name)
        (metadata[:as] || dependency_name).to_sym
      end

      def self.external_effective_input_key(dependency)
        (dependency[:as] || dependency[:node]).to_sym
      end

      def self.validate_retry_max_attempts(value, node_name:, errors:)
        integer = Integer(value)
        errors << "Node #{node_name} retry.max_attempts must be >= 1" if integer < 1
      rescue ArgumentError, TypeError
        errors << "Node #{node_name} retry.max_attempts must be an Integer >= 1"
      end

      def self.validate_retry_backoff(value, node_name:, errors:)
        backoff = value.to_sym
        return if VALID_RETRY_BACKOFFS.include?(backoff)

        errors << "Node #{node_name} retry.backoff must be one of #{VALID_RETRY_BACKOFFS.join(", ")}"
      rescue NoMethodError
        errors << "Node #{node_name} retry.backoff must be one of #{VALID_RETRY_BACKOFFS.join(", ")}"
      end

      def self.validate_retry_delay(value, node_name:, key:, errors:)
        numeric = Float(value)
        errors << "Node #{node_name} retry.#{key} must be >= 0" if numeric.negative?
      rescue ArgumentError, TypeError
        errors << "Node #{node_name} retry.#{key} must be a number >= 0"
      end

      def self.validate_retry_max_delay(config, node_name:, errors:)
        return unless config.key?(:base_delay) && config.key?(:max_delay)

        base_delay = Float(config[:base_delay])
        max_delay = Float(config[:max_delay])
        return unless max_delay < base_delay

        errors << "Node #{node_name} retry.max_delay must be >= retry.base_delay"
      rescue ArgumentError, TypeError
        nil
      end

      def self.validate_retry_on(value, node_name:, errors:)
        unless value.is_a?(Array)
          errors << "Node #{node_name} retry.retry_on must be an array of Symbols or Strings"
          return
        end

        invalid = value.reject { |entry| symbol_like?(entry) }
        return if invalid.empty?

        errors << "Node #{node_name} retry.retry_on entries must be Symbols or Strings"
      end

      def self.blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      def self.symbol_like?(value)
        value.is_a?(Symbol) || value.is_a?(String)
      end

      def self.callable?(value)
        value.respond_to?(:call)
      end
    end
  end
end
