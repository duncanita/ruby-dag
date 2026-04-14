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
        renaming = old_sym != new_step.name

        new_graph = renaming ? graph.with_node_replaced(old_sym, new_step.name) : graph
        new_registry = registry.dup
        if renaming
          new_registry.remove(old_sym)
          new_registry.register(new_step)
          rewrite_run_if_refs(new_registry, old_sym, new_step.name)
        else
          new_registry.replace(new_step)
        end

        Definition.new(graph: new_graph, registry: new_registry)
      end

      private

      def rewrite_run_if_refs(registry, old_sym, new_sym)
        registry.steps.each do |step|
          run_if = step.config[:run_if]
          next unless run_if

          rewritten = Condition.rename_from(run_if, old_sym, new_sym)
          registry.replace(Step.new(name: step.name, type: step.type,
            **step.config.merge(run_if: rewritten)))
        end
      end

      def inspect = "#<DAG::Workflow::Definition nodes=#{graph.size} steps=#{registry.size}>"
      alias_method :to_s, :inspect
    end
  end
end
