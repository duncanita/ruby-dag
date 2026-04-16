# frozen_string_literal: true

module DAG
  module Workflow
    module Condition
      LOGICAL_KEYS = %i[all any not].freeze
      LEAF_KEYS = %i[from status value].freeze
      VALUE_KEYS = %i[equals in present nil matches].freeze
      STATUSES = %i[success skipped].freeze

      class << self
        def normalize(condition, context: "run_if")
          return nil if condition.nil?
          return condition if callable?(condition)

          normalize_condition(condition, context: context)
        end

        def validate(condition, node_name:, graph:, allowed_inputs: nil)
          return [] if condition.nil? || callable?(condition)

          validate_dependencies(condition, node_name: node_name, allowed_inputs: allowed_inputs || graph.predecessors(node_name))
        end

        def validate!(condition, node_name:, graph:)
          errors = validate(condition, node_name: node_name, graph: graph)
          raise ValidationError, errors unless errors.empty?

          condition
        end

        def evaluate(condition, dependency_context)
          return true if condition.nil?
          return condition.call(extract_values(dependency_context)) if callable?(condition)

          evaluate_condition(condition, dependency_context)
        end

        # Returns a new condition with every `:from` reference to `old_name`
        # replaced by `new_name`. Used by Definition#replace_step to keep
        # declarative run_if conditions consistent after a node rename.
        # Returns nil for nil, and passes callables through unchanged.
        def rename_from(condition, old_name, new_name)
          return condition if condition.nil? || callable?(condition)

          old_sym = old_name.to_sym
          new_sym = new_name.to_sym

          map_tree(condition) do |leaf|
            (leaf[:from] == old_sym) ? leaf.merge(from: new_sym) : leaf
          end
        end

        def dumpable(condition)
          raise SerializationError, "run_if is not YAML-serializable when it is callable" if callable?(condition)
          return nil if condition.nil?

          map_tree(condition, all_key: "all", any_key: "any", not_key: "not") do |leaf|
            dump_leaf(leaf)
          end
        end

        def callable?(condition)
          condition.respond_to?(:call)
        end

        private

        def normalize_condition(condition, context:)
          raise ValidationError, "#{context} must be a mapping, got #{condition.inspect}" unless condition.is_a?(Hash)

          hash = symbolize_hash(condition, context: context)
          logical_keys = hash.keys & LOGICAL_KEYS
          return normalize_logical(hash, logical_keys, context: context) unless logical_keys.empty?

          normalize_leaf(hash, context: context)
        end

        # Operands inside logical operators (all/any/not) must be concrete
        # condition mappings — not nil and not callables. At the top level,
        # nil means "no condition" and a callable is a pass-through; inside
        # a logical tree neither makes sense and would crash evaluate.
        def normalize_operand(entry, context:)
          raise ValidationError, "#{context} must be a condition mapping, got nil" if entry.nil?
          raise ValidationError, "#{context} must be a condition mapping, not a callable" if callable?(entry)

          normalize_condition(entry, context: context)
        end

        def normalize_logical(hash, logical_keys, context:)
          if logical_keys.size != 1 || hash.size != 1
            raise ValidationError,
              "#{context} must contain exactly one logical operator (#{LOGICAL_KEYS.join(", ")})"
          end

          key = logical_keys.first
          value = hash.fetch(key)

          case key
          when :all, :any
            raise ValidationError, "#{context}.#{key} must be a non-empty array" unless value.is_a?(Array) && !value.empty?

            {key => value.each_with_index.map { |entry, index|
              normalize_operand(entry, context: "#{context}.#{key}[#{index}]")
            }}
          when :not
            {not: normalize_operand(value, context: "#{context}.not")}
            # :nocov: unreachable — key is pre-validated against LOGICAL_KEYS
          else raise "unexpected logical key: #{key}"
            # :nocov:
          end
        end

        def normalize_leaf(hash, context:)
          unknown = hash.keys - LEAF_KEYS
          unless unknown.empty?
            raise ValidationError,
              "#{context} has unsupported keys #{unknown.map(&:inspect).join(", ")}. " \
              "Allowed: #{LEAF_KEYS.join(", ")} or #{LOGICAL_KEYS.join(", ")}"
          end

          raise ValidationError, "#{context} must include :from" unless hash.key?(:from)
          raise ValidationError, "#{context} must include :status and/or :value" unless hash.key?(:status) || hash.key?(:value)

          normalized = {from: coerce_symbol!(hash[:from], context: "#{context}.from")}
          normalized[:status] = normalize_status(hash[:status], context: "#{context}.status") if hash.key?(:status)
          normalized[:value] = normalize_value(hash[:value], context: "#{context}.value") if hash.key?(:value)
          normalized
        end

        def normalize_status(status, context:)
          sym = coerce_symbol!(status, context: context)
          raise ValidationError, "#{context} must be one of #{STATUSES.join(", ")}" unless STATUSES.include?(sym)

          sym
        end

        def normalize_value(value, context:)
          raise ValidationError, "#{context} must be a mapping" unless value.is_a?(Hash)

          hash = symbolize_hash(value, context: context)
          raise ValidationError, "#{context} must contain exactly one predicate" unless hash.size == 1

          key, expected = hash.first
          raise ValidationError, "#{context} must use one of #{VALUE_KEYS.join(", ")}" unless VALUE_KEYS.include?(key)

          case key
          when :equals
            validate_yaml_safe!(expected, context: "#{context}.equals")
            {equals: expected}
          when :in
            raise ValidationError, "#{context}.in must be a non-empty array" unless expected.is_a?(Array) && !expected.empty?
            expected.each_with_index { |v, i| validate_yaml_safe!(v, context: "#{context}.in[#{i}]") }

            {in: expected}
          when :present
            raise ValidationError, "#{context}.present must be true" unless expected == true

            {present: true}
          when :nil
            raise ValidationError, "#{context}.nil must be true" unless expected == true

            {nil: true}
          when :matches
            raise ValidationError, "#{context}.matches must be a non-empty string" unless expected.is_a?(String) && !expected.empty?

            begin
              verbose, $VERBOSE = $VERBOSE, nil
              Regexp.new(expected)
            ensure
              $VERBOSE = verbose
            end
            {matches: expected}
            # :nocov: unreachable — key is pre-validated against VALUE_KEYS
          else raise "unexpected value predicate: #{key}"
            # :nocov:
          end
        rescue RegexpError => e
          raise ValidationError, "#{context}.matches is not a valid regular expression: #{e.message}"
        end

        def validate_dependencies(condition, node_name:, allowed_inputs:)
          errors = []
          each_leaf(condition) do |leaf|
            from = leaf.fetch(:from)
            next if allowed_inputs.include?(from)

            deps = allowed_inputs.to_a.sort
            errors << if deps.empty?
              "Node '#{node_name}' has a run_if that references '#{from}', but it has no direct dependencies"
            else
              "Node '#{node_name}' run_if references '#{from}', but only direct dependencies are allowed: #{deps.join(", ")}"
            end
          end
          errors
        end

        def evaluate_condition(condition, dependency_context)
          dispatch_tree(
            condition,
            on_all: ->(entries) { entries.all? { |entry| evaluate_condition(entry, dependency_context) } },
            on_any: ->(entries) { entries.any? { |entry| evaluate_condition(entry, dependency_context) } },
            on_not: ->(entry) { !evaluate_condition(entry, dependency_context) },
            on_leaf: ->(leaf) { evaluate_leaf(leaf, dependency_context) }
          )
        end

        def evaluate_leaf(condition, dependency_context)
          context = dependency_context.fetch(condition[:from])
          matches_status?(condition, context) && matches_value?(condition, context)
        end

        def matches_status?(condition, context)
          return true unless condition.key?(:status)

          context[:status] == condition[:status]
        end

        def matches_value?(condition, context)
          return true unless condition.key?(:value)

          actual = context[:value]
          predicate, expected = condition[:value].first

          case predicate
          when :equals
            actual == expected
          when :in
            expected.include?(actual)
          when :present
            present?(actual)
          when :nil
            actual.nil?
          when :matches
            actual.is_a?(String) && Regexp.new(expected).match?(actual)
            # :nocov: unreachable — predicate comes from normalized condition
          else raise "unexpected value predicate: #{predicate}"
            # :nocov:
          end
        end

        # Callables receive the same value-only input hash that Runner
        # passes to step executors: {dep_name: value, ...}. This matches
        # the contract that Runner#skip? uses for callable run_if.
        def extract_values(dependency_context)
          dependency_context.transform_values { |entry| entry[:value] }
        end

        def present?(value)
          return false if value.nil?
          return !value.empty? if value.respond_to?(:empty?)

          true
        end

        def dump_leaf(condition)
          node = {"from" => condition[:from].to_s}
          node["status"] = condition[:status].to_s if condition.key?(:status)
          if condition.key?(:value)
            predicate, expected = condition[:value].first
            node["value"] = {predicate.to_s => expected}
          end
          node
        end

        def map_tree(condition, all_key: :all, any_key: :any, not_key: :not, &block)
          dispatch_tree(
            condition,
            on_all: ->(entries) {
              {all_key => entries.map { |entry|
                map_tree(entry,
                  all_key: all_key, any_key: any_key, not_key: not_key, &block)
              }}
            },
            on_any: ->(entries) {
              {any_key => entries.map { |entry|
                map_tree(entry,
                  all_key: all_key, any_key: any_key, not_key: not_key, &block)
              }}
            },
            on_not: ->(entry) {
              {not_key => map_tree(entry,
                all_key: all_key, any_key: any_key, not_key: not_key, &block)}
            },
            on_leaf: ->(leaf) { block.call(leaf) }
          )
        end

        def each_leaf(condition, &block)
          dispatch_tree(
            condition,
            on_all: ->(entries) { entries.each { |entry| each_leaf(entry, &block) } },
            on_any: ->(entries) { entries.each { |entry| each_leaf(entry, &block) } },
            on_not: ->(entry) { each_leaf(entry, &block) },
            on_leaf: ->(leaf) { block.call(leaf) }
          )
        end

        def dispatch_tree(condition, on_all:, on_any:, on_not:, on_leaf:)
          if condition.key?(:all)
            on_all.call(condition[:all])
          elsif condition.key?(:any)
            on_any.call(condition[:any])
          elsif condition.key?(:not)
            on_not.call(condition[:not])
          else
            on_leaf.call(condition)
          end
        end

        YAML_SAFE_TYPES = [String, Symbol, Integer, Float, NilClass, TrueClass, FalseClass].freeze

        def validate_yaml_safe!(value, context:)
          return if YAML_SAFE_TYPES.any? { |t| value.is_a?(t) }

          raise ValidationError,
            "#{context} must be a YAML-safe value (String, Symbol, Integer, Float, " \
            "true, false, nil), got #{value.class}"
        end

        def symbolize_hash(hash, context:)
          hash.each_with_object({}) do |(key, value), memo|
            memo[coerce_symbol!(key, context: "#{context} key")] = value
          end
        end

        def coerce_symbol!(value, context:)
          value.to_sym
        rescue NoMethodError, TypeError
          raise ValidationError, "#{context} must be symbolizable, got #{value.inspect}"
        end
      end
    end
  end
end
