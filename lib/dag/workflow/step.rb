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
        super(
          name: name.to_sym,
          type: type.to_sym,
          config: deep_copy_and_freeze(config, {})
        )
      end

      def to_s = "Step(#{name}:#{type})"
      def inspect = to_s

      private

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
