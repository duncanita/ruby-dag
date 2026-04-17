# frozen_string_literal: true

module DAG
  module Workflow
    class << self
      def replace_subtree(definition, root_node:, replacement:, reconnect: [])
        raise ArgumentError, "definition must be a DAG::Workflow::Definition" unless definition.is_a?(Definition)
        raise ArgumentError, "replacement must be a DAG::Workflow::Definition" unless replacement.is_a?(Definition)

        root = root_node.to_sym
        removed = [root]

        new_graph = definition.graph.with_subtree_replaced(
          root: root,
          replacement_graph: replacement.graph,
          reconnect: reconnect
        )
        new_registry = definition.registry.dup
        removed.each { |name| new_registry.remove(name) }
        replacement.registry.steps.each { |step| new_registry.register(step) }

        Definition.new(graph: new_graph, registry: new_registry, source_path: definition.source_path)
      end
    end
  end
end
