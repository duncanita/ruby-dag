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

      private

      def normalize_node_path(node_path)
        Array(node_path).map(&:to_sym).freeze
      end
    end
  end
end
