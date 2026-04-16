# frozen_string_literal: true

module DAG
  module Workflow
    class AttemptTraceMiddleware < StepMiddleware
      def initialize(clock: Clock.new)
        @clock = clock
      end

      def call(step, input, context:, execution:, next_step:)
        started_at = @clock.monotonic_now
        result = next_step.call(step, input, context: context, execution: execution)
        finished_at = @clock.monotonic_now

        append_attempt_trace(execution, result, started_at: started_at, finished_at: finished_at)
        result
      end

      private

      def append_attempt_trace(execution, result, started_at:, finished_at:)
        return if lifecycle_payload?(result)
        return unless execution.event_bus

        execution.event_bus << AttemptTraceEntry.new(
          node_path: execution.node_path,
          started_at: started_at,
          finished_at: finished_at,
          duration_ms: ((finished_at - started_at) * 1000).round(2),
          status: result.success? ? :success : :failure,
          attempt: execution.attempt
        )
      end

      def lifecycle_payload?(result)
        return false unless result.success? && result.value.is_a?(Hash)

        %i[waiting paused].include?(result.value[:__sub_workflow_status__])
      end
    end
  end
end
