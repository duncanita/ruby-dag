# frozen_string_literal: true

module DAG
  module Workflow
    # Bundles a Graph + Registry into a complete workflow definition.
    # Returned by Loader, consumed by Runner.
    #
    #   definition = DAG::Loader.from_file("workflow.yml")
    #   result = DAG::Runner.new(definition.graph, definition.registry).call

    Definition = Data.define(:graph, :registry) do
      def size = graph.size

      def execution_order = graph.topological_layers

      def step(name) = registry[name]

      def inspect = "#<DAG::Workflow::Definition nodes=#{graph.size} steps=#{registry.size}>"
      alias_method :to_s, :inspect
    end
  end
end
