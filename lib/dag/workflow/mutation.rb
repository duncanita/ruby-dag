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
        normalized_reconnect = Array(reconnect).map do |descriptor|
          normalize_reconnect_alias_entry(descriptor, graph: graph, root: root)
        end

        normalized_reconnect.each do |entry|
          target = entry.fetch(:to)
          aliases = aliases_by_target[target]

          graph.each_predecessor(target) do |predecessor|
            next if predecessor == root

            aliases << effective_input_key(predecessor, graph.edge_metadata(predecessor, target))
          end
        end

        normalized_reconnect.each do |entry|
          target = entry.fetch(:to)
          merged = graph.merged_edge_metadata(root, target, entry[:metadata])
          alias_key = effective_input_key(entry.fetch(:from), merged)

          if aliases_by_target[target].include?(alias_key)
            raise ArgumentError, "duplicate effective downstream alias for #{target}: #{alias_key}"
          end

          aliases_by_target[target] << alias_key
        end
      end

      def normalize_reconnect_alias_entry(descriptor, graph:, root:)
        raise ArgumentError, "reconnect entries must be Hashes" unless descriptor.is_a?(Hash)

        entry = descriptor.transform_keys(&:to_sym)
        raise ArgumentError, "reconnect entries must include :from" unless entry.key?(:from)
        raise ArgumentError, "reconnect entries must include :to" unless entry.key?(:to)

        {
          from: entry.fetch(:from).to_sym,
          to: entry.fetch(:to).to_sym,
          metadata: graph.merged_edge_metadata(root, entry.fetch(:to), entry[:metadata])
        }
      end

      def effective_input_key(from, metadata)
        (metadata[:as] || from).to_sym
      end
    end
  end
end
