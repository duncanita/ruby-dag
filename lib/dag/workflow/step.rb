# frozen_string_literal: true

module DAG
  module Workflow
    # Execution config for a workflow step. Pure data, no graph awareness.
    # Replaces the old Node class as the carrier of step type and configuration.
    #
    #   step = DAG::Workflow::Step.new(name: :fetch, type: :exec, command: "curl ...")
    #   step.type    # => :exec
    #   step.config  # => {command: "curl ..."}

    Step = Data.define(:name, :type, :config) do
      SHAREABLE_TYPES = %i[exec script file_read file_write llm].freeze

      def initialize(name:, type:, **config)
        super(
          name: name.to_sym,
          type: type.to_sym,
          config: config.freeze
        )
        return unless SHAREABLE_TYPES.include?(self.type)

        Ractor.make_shareable(self)
      rescue Ractor::Error => e
        raise ArgumentError, "Step #{name} contains non-shareable values: #{e.message}. Parallel execution requires JSON-like config values."
      end

      def to_s = "Step(#{name}:#{type})"
      def inspect = to_s
    end
  end
end
