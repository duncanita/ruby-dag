# frozen_string_literal: true

module DAG
  module Workflow
    class << self
      def replace_subtree(definition, root_node:, replacement:, reconnect: [])
        raise ArgumentError, "definition must be a DAG::Workflow::Definition" unless definition.is_a?(Definition)
        raise ArgumentError, "replacement must be a DAG::Workflow::Definition" unless replacement.is_a?(Definition)

        root = root_node.to_sym
        removed = [root]
        validate_reconnect_aliases!(definition.graph, root, reconnect)

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

      private

      def validate_reconnect_aliases!(graph, root, reconnect)
        aliases_by_target = Hash.new { |hash, key| hash[key] = Set.new }

        Array(reconnect).each do |descriptor|
          entry = descriptor.transform_keys(&:to_sym)
          target = entry.fetch(:to).to_sym
          aliases = aliases_by_target[target]

          graph.each_predecessor(target) do |predecessor|
            next if predecessor == root

            aliases << effective_input_key(predecessor, graph.edge_metadata(predecessor, target))
          end
        end

        Array(reconnect).each do |descriptor|
          entry = descriptor.transform_keys(&:to_sym)
          target = entry.fetch(:to).to_sym
          merged = graph.merged_edge_metadata(root, target, entry[:metadata])
          alias_key = effective_input_key(entry.fetch(:from), merged)

          if aliases_by_target[target].include?(alias_key)
            raise ArgumentError, "duplicate effective downstream alias for #{target}: #{alias_key}"
          end

          aliases_by_target[target] << alias_key
        end
      end

      def effective_input_key(from, metadata)
        (metadata[:as] || from).to_sym
      end
    end
  end
end
