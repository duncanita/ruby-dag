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
          config: deep_freeze(config)
        )
      end

      def to_s = "Step(#{name}:#{type})"
      def inspect = to_s

      private

      def deep_freeze(obj)
        case obj
        when Hash then obj.each_value { |v| deep_freeze(v) }.freeze
        when Array then obj.each { |v| deep_freeze(v) }.freeze
        else obj.freeze if obj.respond_to?(:freeze) && !obj.frozen?
        end
        obj
      end
    end
  end
end
