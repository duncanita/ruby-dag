# frozen_string_literal: true

module DAG
  module Workflow
    class TraceRecorder
      def initialize(callbacks:)
        @callbacks = callbacks
      end

      def record_immediate_results(entries:, results:, statuses:, layer_index:, trace:, node_path_for:)
        entries.each do |entry|
          trace_entry = build_trace_entry(
            node_path_for.call(entry.name),
            layer_index,
            entry.result,
            started_at: nil,
            finished_at: nil,
            duration_ms: 0,
            input_keys: entry.input_keys,
            status: entry.status
          )
          trace << trace_entry
          statuses[entry.name] = trace_entry.status
          @callbacks.finish(entry.name, entry.result)
          results[entry.name] = entry.result
        end
      end

      def build_trace_entries_for_task(task:, layer_index:, result:, started_at:, finished_at:, duration_ms:, lifecycle_payload:)
        if task.attempt_log.empty?
          return [] if lifecycle_payload

          return [build_trace_entry(task.execution.node_path, layer_index, result,
            started_at: started_at,
            finished_at: finished_at,
            duration_ms: duration_ms,
            input_keys: task.input_keys)]
        end

        attempt_entries, passthrough_entries = partition_attempt_entries(task.attempt_log)
        attempt_trace = attempt_entries.each_with_index.map do |entry, index|
          build_trace_entry(entry.node_path, layer_index, result,
            started_at: entry.started_at,
            finished_at: entry.finished_at,
            duration_ms: entry.duration_ms,
            input_keys: task.input_keys,
            status: entry.status,
            attempt: entry.attempt,
            retried: index < (attempt_entries.length - 1))
        end

        attempt_trace + passthrough_entries
      end

      def observed_status_for_task(task:, result:, entries:)
        task_name = trace_name_for(task.execution.node_path)
        task_entries = entries.select { |entry| entry.name == task_name }
        return task_entries.last.status if task_entries.any?

        result.success? ? :success : :failure
      end

      private

      def partition_attempt_entries(entries)
        attempt_entries = []
        passthrough_entries = []

        entries.each do |entry|
          if entry.is_a?(AttemptTraceEntry)
            attempt_entries << entry
          else
            passthrough_entries << entry
          end
        end

        [attempt_entries, passthrough_entries]
      end

      def build_trace_entry(node_path, layer_index, result, started_at:, finished_at:, duration_ms:, input_keys:, status: nil, attempt: 1, retried: false)
        TraceEntry.new(
          name: trace_name_for(node_path),
          layer: layer_index,
          started_at: started_at,
          finished_at: finished_at,
          duration_ms: duration_ms,
          status: status || (result.success? ? :success : :failure),
          input_keys: input_keys,
          attempt: attempt,
          retried: retried
        )
      end

      def trace_name_for(node_path)
        path = Array(node_path).map(&:to_sym)
        return path.first if path.length == 1

        path.join(".").to_sym
      end
    end
  end
end
