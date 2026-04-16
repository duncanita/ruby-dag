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

      def invalidate(workflow_id:, node:, definition:, execution_store:, max_cascade_depth: nil, cause: nil)
        root = normalize_node_path(node)
        run = execution_store.load_run(workflow_id)
        return [] unless run

        resolved = resolve_definition_for_node_path(definition:, node_path: root)
        cascaded_paths = cascade_node_paths(
          definition: resolved[:definition],
          prefix: resolved[:prefix],
          root_name: resolved[:root_name],
          max_cascade_depth: max_cascade_depth
        )
        invalidated = (ancestor_node_paths(root) + cascaded_paths).uniq.select do |node_path|
          run.dig(:nodes, node_path, :state) == :completed
        end
        return [] if invalidated.empty?

        execution_store.mark_stale(
          workflow_id: workflow_id,
          node_paths: invalidated,
          cause: invalidation_cause(root, cause)
        )

        invalidated.sort_by { |node_path| node_path.map(&:to_s) }
      end

      private

      def cascade_node_paths(definition:, prefix:, root_name:, max_cascade_depth:)
        graph = definition.graph
        raise ArgumentError, "unknown node: #{root_name.inspect}" unless graph.node?(root_name)

        queue = [[root_name, 0]]
        visited = Set.new([root_name])
        paths = []

        until queue.empty?
          current_name, depth = queue.shift
          paths << (prefix + [current_name])
          next if max_cascade_depth && depth >= max_cascade_depth

          graph.each_successor(current_name) do |successor|
            next if visited.include?(successor)

            visited << successor
            queue << [successor, depth + 1]
          end
        end

        paths.map { |node_path| normalize_node_path(node_path) }
      end

      def resolve_definition_for_node_path(definition:, node_path:)
        raise ArgumentError, "node path must not be empty" if node_path.empty?

        current_definition = definition
        prefix = []

        node_path[0...-1].each do |segment|
          step = current_definition.step(segment)
          raise ArgumentError, "unknown node: #{segment.inspect}" unless step
          raise ArgumentError, "node path segment #{segment.inspect} is not a sub_workflow" unless step.type == :sub_workflow

          current_definition = SubWorkflowSupport.resolve_definition(step, source_path: current_definition.source_path)
          prefix << segment
        end

        {
          definition: current_definition,
          prefix: normalize_node_path(prefix),
          root_name: node_path.last
        }
      end

      def ancestor_node_paths(node_path)
        return [] if node_path.size < 2

        (1...node_path.size).map do |length|
          normalize_node_path(node_path.first(length))
        end
      end

      def invalidation_cause(root, custom_cause)
        {code: :manual_invalidation}.merge(normalize_cause(custom_cause)).merge(invalidated_from: root)
      end

      def normalize_cause(cause)
        return {} if cause.nil?
        raise ArgumentError, "cause must be a Hash" unless cause.is_a?(Hash)

        cause.transform_keys(&:to_sym)
      end

      def normalize_node_path(node_path)
        Array(node_path).map(&:to_sym).freeze
      end
    end
  end
end
