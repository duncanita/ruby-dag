# frozen_string_literal: true

module DAG
  module Workflow
    # Maps node names (symbols) to Steps. Paired with a Graph to form a complete workflow.
    #
    #   registry = DAG::Workflow::Registry.new
    #   registry.register(DAG::Workflow::Step.new(name: :fetch, type: :exec, command: "curl ..."))
    #   registry[:fetch]  # => Step(fetch:exec)

    class Registry
      def initialize
        @steps = {}
      end

      def register(step)
        raise ArgumentError, "Duplicate step: #{step.name}" if @steps.key?(step.name)

        @steps[step.name] = step
        self
      end

      def [](name)
        @steps.fetch(name.to_sym) { raise ArgumentError, "Unknown step: #{name}" }
      end

      def steps = @steps.values
      def size = @steps.size
      def empty? = @steps.empty?
      def key?(name) = @steps.key?(name.to_sym)

      def inspect
        "#<DAG::Workflow::Registry steps=#{@steps.keys}>"
      end
      alias_method :to_s, :inspect
    end
  end
end
