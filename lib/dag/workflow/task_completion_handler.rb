# frozen_string_literal: true

module DAG
  module Workflow
    TaskCompletionOutcome = Data.define(:waiting_nodes, :paused)

    class TaskCompletionHandler
      def initialize(trace_recorder:, execution_persistence:, callbacks:, lifecycle_callback_result: ->(_lifecycle) { Success.new(value: nil) })
        @trace_recorder = trace_recorder
        @execution_persistence = execution_persistence
        @callbacks = callbacks
        @lifecycle_callback_result = lifecycle_callback_result
      end

      def handle(task:, outcome:, layer_index:, trace:, results:, statuses:, lifecycle_payload:)
        result = outcome.result
        entries = @trace_recorder.build_trace_entries_for_task(
          task: task,
          layer_index: layer_index,
          outcome: outcome,
          lifecycle_payload: lifecycle_payload
        )
        trace.concat(entries)
        @execution_persistence.persist_step_result(task, result, entries, skip_result: !lifecycle_payload.nil?)

        if lifecycle_payload
          statuses[task.name] = lifecycle_payload[:status]
          persist_lifecycle_node(task.name, lifecycle_payload[:status])
          @callbacks.finish(task.name, @lifecycle_callback_result.call(lifecycle_payload))
          return TaskCompletionOutcome.new(
            waiting_nodes: (lifecycle_payload[:status] == :waiting) ? lifecycle_payload[:waiting_nodes] : [],
            paused: lifecycle_payload[:status] == :paused
          )
        end

        statuses[task.name] = @trace_recorder.observed_status_for_task(task: task, result: result, entries: entries)
        @callbacks.finish(task.name, result)
        results[task.name] = result

        TaskCompletionOutcome.new(waiting_nodes: [], paused: false)
      end

      private

      def persist_lifecycle_node(name, status)
        case status
        when :waiting then @execution_persistence.persist_waiting_node(name)
        when :paused then @execution_persistence.persist_paused_node(name)
        end
      end
    end
  end
end
