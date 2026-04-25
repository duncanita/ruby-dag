# frozen_string_literal: true

module DAG
  module Workflow
    class ExecutionPersistence
      def initialize(execution_store:, workflow_id:, registry:, clock:, node_path_prefix: [])
        @execution_store = execution_store
        @workflow_id = workflow_id
        @registry = registry
        @clock = clock
        @node_path_prefix = Array(node_path_prefix).map(&:to_sym).freeze
      end

      def node_path_for(name)
        @node_path_prefix + [name.to_sym]
      end

      def pause_requested?
        return false unless enabled?

        if @execution_store.respond_to?(:paused?)
          @execution_store.paused?(@workflow_id)
        else
          @execution_store.load_run(@workflow_id)&.fetch(:paused, false)
        end
      end

      def set_workflow_status(status:, waiting_nodes: [])
        return unless enabled?

        @execution_store.set_workflow_status(
          workflow_id: @workflow_id,
          status: status,
          waiting_nodes: waiting_nodes
        )
      end

      def clear_run
        return unless enabled?
        return unless @execution_store.respond_to?(:clear_run)

        @execution_store.clear_run(workflow_id: @workflow_id)
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

      def persist_paused_node(name)
        return unless enabled?

        @execution_store.set_node_state(
          workflow_id: @workflow_id,
          node_path: node_path_for(name),
          state: :paused,
          metadata: {}
        )
      end

      def persist_expired_schedule_node(name, error)
        persist_failed_schedule_node(name, error)
      end

      def persist_impossible_schedule_window(name, error)
        persist_failed_schedule_node(name, error)
      end

      def persist_failed_schedule_node(name, error)
        return unless enabled?

        @execution_store.set_node_state(
          workflow_id: @workflow_id,
          node_path: node_path_for(name),
          state: :failed,
          reason: error,
          metadata: {}
        )
      end
      private :persist_failed_schedule_node

      def load_reusable_result(name, schedule_policy: nil)
        return nil unless enabled?

        stored = @execution_store.load_output(workflow_id: @workflow_id, node_path: node_path_for(name))
        return nil unless stored

        policy = schedule_policy || SchedulePolicy.new(@registry[name], clock: @clock)
        if policy.reusable_output_expired?(stored)
          @execution_store.mark_stale(
            workflow_id: @workflow_id,
            node_paths: [node_path_for(name)],
            cause: policy.ttl_expired_cause(name, stored)
          )
          return nil
        end

        stored[:result]
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
            version: next_output_version(task.execution.node_path),
            result: result,
            reusable: true,
            superseded: false,
            saved_at: @clock.wall_now
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

      def next_output_version(node_path)
        if @execution_store.respond_to?(:next_output_version)
          return @execution_store.next_output_version(workflow_id: @workflow_id, node_path: node_path)
        end

        stored_versions = Array(@execution_store.load_output(
          workflow_id: @workflow_id,
          node_path: node_path,
          version: :all
        )).map { |entry| entry[:version] }

        (stored_versions.max || 0) + 1
      end

      def enabled?
        @execution_store && @workflow_id
      end
    end
  end
end
