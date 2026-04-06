# frozen_string_literal: true

module DAG
  module Workflow
    # Execution config for a workflow step. Pure data, no graph awareness.
    #
    #   step = DAG::Workflow::Step.new(name: :fetch, type: :exec, command: "curl ...")
    #   step.type    # => :exec
    #   step.config  # => {command: "curl ..."}

    Step = Data.define(:name, :type, :config) do
      def initialize(name:, type:, **config)
        super(
          name: name.to_sym,
          type: type.to_sym,
          config: config.freeze
        )
        return if self.type == :ruby

        Ractor.make_shareable(self)
      rescue Ractor::Error => e
        # Non-shareable config; step will run sequentially. Surface this once
        # per step so users with parallel: true know why a layer degraded.
        warn "[DAG::Workflow::Step] #{self.name} (#{self.type}) is not Ractor-shareable: #{e.message}. " \
             "This step will run sequentially even when parallel: true."
      end

      def ractor_safe?
        Ractor.shareable?(self)
      end

      def to_s = "Step(#{name}:#{type})"
      def inspect = to_s
    end
  end
end
