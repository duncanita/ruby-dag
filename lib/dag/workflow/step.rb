# frozen_string_literal: true

module DAG
  module Workflow
    # Execution config for a workflow step. Pure data, no graph or runtime
    # awareness — Step does not know about Ractors, Threads, or processes.
    # The Ractors strategy is the one place that asks "is this step shareable?",
    # and it does so lazily; everywhere else a Step is just a frozen value.
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
      end

      def to_s = "Step(#{name}:#{type})"
      def inspect = to_s
    end
  end
end
