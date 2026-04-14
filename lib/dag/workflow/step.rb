# frozen_string_literal: true

module DAG
  module Workflow
    # Execution config for a workflow step. Pure data, no graph or runtime
    # awareness — Step does not know about Threads or processes. Anywhere a
    # Step appears it is just a frozen value.
    #
    #   step = DAG::Workflow::Step.new(name: :fetch, type: :exec, command: "curl ...")
    #   step.type    # => :exec
    #   step.config  # => {command: "curl ..."}

    Step = Data.define(:name, :type, :config) do
      def initialize(name:, type:, **config)
        sym_name = name.to_sym
        super(
          name: sym_name,
          type: type.to_sym,
          config: deep_copy_and_freeze(canonicalize_run_if(config, node_name: sym_name), {})
        )
      end

      def to_s = "Step(#{name}:#{type})"
      def inspect = to_s

      private

      def canonicalize_run_if(config, node_name:)
        return config unless config.key?(:run_if)

        run_if = config[:run_if]
        # For Ruby construction APIs, `run_if: nil` is equivalent to omitting
        # the condition entirely. YAML stays stricter in Loader.
        return config.except(:run_if) if run_if.nil?

        config.merge(run_if: Condition.normalize(run_if, context: "run_if for node '#{node_name}'"))
      end

      def deep_copy_and_freeze(obj, seen)
        return seen[obj.object_id] if seen.key?(obj.object_id)

        case obj
        when Hash
          copy = {}
          seen[obj.object_id] = copy
          obj.each do |key, value|
            copy[deep_copy_and_freeze(key, seen)] = deep_copy_and_freeze(value, seen)
          end
          copy.freeze
        when Array
          copy = []
          seen[obj.object_id] = copy
          obj.each { |value| copy << deep_copy_and_freeze(value, seen) }
          copy.freeze
        else
          copy = immutable_leaf?(obj) ? obj : safe_dup(obj)
          seen[obj.object_id] = copy
          copy.freeze if copy.respond_to?(:freeze) && !copy.frozen?
          copy
        end
      end

      def immutable_leaf?(obj)
        obj.is_a?(Symbol) || obj.is_a?(Integer) || obj.is_a?(Float) ||
          obj.nil? || obj == true || obj == false
      end

      def safe_dup(obj)
        obj.dup
      rescue TypeError
        obj
      end
    end
  end
end
