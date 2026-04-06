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
      def empty? = graph.empty? && registry.empty?
      def steps = registry.steps

      def execution_order = graph.topological_layers

      def step(name) = registry[name]

      def replace_step(old_name, new_step)
        old_sym = old_name.to_sym

        new_graph = (old_sym == new_step.name) ? graph : graph.with_node_replaced(old_sym, new_step.name)
        new_registry = registry.dup.tap do |r|
          if old_sym == new_step.name
            r.replace(new_step)
          else
            r.remove(old_sym)
            r.register(new_step)
          end
        end

        Definition.new(graph: new_graph, registry: new_registry)
      end

      def inspect = "#<DAG::Workflow::Definition nodes=#{graph.size} steps=#{registry.size}>"
      alias_method :to_s, :inspect
    end
  end
end
