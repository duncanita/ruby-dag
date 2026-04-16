# frozen_string_literal: true

module DAG
  module Workflow
    class << self
      def stale_nodes(workflow_id:, execution_store:)
        run = execution_store.load_run(workflow_id)
        return [] unless run

        Array(run[:nodes]).filter_map do |node_path, node|
          normalize_node_path(node_path || node[:node_path]) if node[:state] == :stale
        end.sort_by { |node_path| node_path.map(&:to_s) }
      end

      def invalidate(workflow_id:, node:, definition:, execution_store:, max_cascade_depth: nil)
        root = normalize_root_node(node)
        run = execution_store.load_run(workflow_id)
        return [] unless run

        invalidated = cascade_node_paths(root:, definition:, max_cascade_depth: max_cascade_depth).select do |node_path|
          run.dig(:nodes, node_path, :state) == :completed
        end
        return [] if invalidated.empty?

        execution_store.mark_stale(
          workflow_id: workflow_id,
          node_paths: invalidated,
          cause: invalidation_cause(root)
        )

        invalidated.sort_by { |node_path| node_path.map(&:to_s) }
      end

      private

      def cascade_node_paths(root:, definition:, max_cascade_depth:)
        graph = definition.graph
        root_name = root.fetch(0)
        raise ArgumentError, "unknown node: #{root_name.inspect}" unless graph.node?(root_name)

        queue = [[root_name, 0]]
        visited = Set.new([root_name])
        paths = []

        until queue.empty?
          current_name, depth = queue.shift
          paths << [current_name]
          next if max_cascade_depth && depth >= max_cascade_depth

          graph.each_successor(current_name) do |successor|
            next if visited.include?(successor)

            visited << successor
            queue << [successor, depth + 1]
          end
        end

        paths.map { |node_path| normalize_node_path(node_path) }
      end

      def invalidation_cause(root)
        {
          code: :manual_invalidation,
          invalidated_from: root
        }
      end

      def normalize_root_node(node)
        normalized = normalize_node_path(node)
        raise ArgumentError, "node path must identify a top-level node" unless normalized.size == 1

        normalized
      end

      def normalize_node_path(node_path)
        Array(node_path).map(&:to_sym).freeze
      end
    end
  end
end
