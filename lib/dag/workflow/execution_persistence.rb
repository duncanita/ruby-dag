# frozen_string_literal: true

module DAG
  module Workflow
    class ExecutionPersistence
      def initialize(execution_store:, workflow_id:, node_path_prefix: [])
        @execution_store = execution_store
        @workflow_id = workflow_id
        @node_path_prefix = Array(node_path_prefix).map(&:to_sym).freeze
      end

      def node_path_for(name)
        @node_path_prefix + [name.to_sym]
      end

      def pause_requested?
        return false unless enabled?

        @execution_store.load_run(@workflow_id)&.fetch(:paused, false)
      end

      def set_workflow_status(status:, waiting_nodes: [])
        return unless enabled?

        @execution_store.set_workflow_status(
          workflow_id: @workflow_id,
          status: status,
          waiting_nodes: waiting_nodes
        )
      end

      def persist_waiting_node(name)
        return unless enabled?

        @execution_store.set_node_state(
          workflow_id: @workflow_id,
          node_path: node_path_for(name),
          state: :waiting,
          metadata: {}
        )
      end

      def persist_expired_schedule_node(name, error)
        return unless enabled?

        @execution_store.set_node_state(
          workflow_id: @workflow_id,
          node_path: node_path_for(name),
          state: :failed,
          reason: error,
          metadata: {}
        )
      end

      def load_reusable_result(name)
        return nil unless enabled?

        stored = @execution_store.load_output(workflow_id: @workflow_id, node_path: node_path_for(name))
        stored && stored[:result]
      end

      def persist_step_result(task, result, entries, skip_result: false)
        return unless enabled?
        return if skip_result

        entries.each do |entry|
          @execution_store.append_trace(workflow_id: @workflow_id, entry: entry)
        end

        if result.success?
          @execution_store.set_node_state(
            workflow_id: @workflow_id,
            node_path: task.execution.node_path,
            state: :completed
          )
          @execution_store.save_output(
            workflow_id: @workflow_id,
            node_path: task.execution.node_path,
            version: task.execution.attempt,
            result: result,
            reusable: true,
            superseded: false
          )
        else
          @execution_store.set_node_state(
            workflow_id: @workflow_id,
            node_path: task.execution.node_path,
            state: :failed,
            reason: result.error,
            metadata: {}
          )
        end
      end

      private

      def enabled?
        @execution_store && @workflow_id
      end
    end
  end
end
