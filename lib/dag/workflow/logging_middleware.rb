# frozen_string_literal: true

module DAG
  module Workflow
    class LoggingMiddleware < StepMiddleware
      class << self
        def format(event)
          parts = [event.fetch(:event), event.fetch(:node_path).join("."), "attempt=#{event.fetch(:attempt)}"]
          parts << "step_type=#{event.fetch(:step_type)}"
          parts << "input_keys=#{event[:input_keys]}" if event.key?(:input_keys)
          parts << "status=#{event[:status]}" if event.key?(:status)
          parts << "error_class=#{event[:error_class]}" if event.key?(:error_class)
          parts << "error_message=#{event[:error_message]}" if event.key?(:error_message)
          parts.join(" ")
        end
      end

      def initialize(logger: nil)
        @logger = logger || ->(event) { warn(self.class.format(event)) }
      end

      def call(step, input, context:, execution:, next_step:)
        log(start_event(step, execution, input))
        result = next_step.call(step, input, context: context, execution: execution)
        log(finish_event(step, execution, result))
        result
      rescue => e
        log(raised_event(step, execution, e))
        raise
      end

      private

      def start_event(step, execution, input)
        base_event(:starting, step, execution).merge(
          input_keys: input.is_a?(Hash) ? input.keys.map(&:to_sym) : []
        )
      end

      def finish_event(step, execution, result)
        base_event(:finished, step, execution).merge(
          status: result.success? ? :ok : :fail
        )
      end

      def raised_event(step, execution, error)
        base_event(:raised, step, execution).merge(
          error_class: error.class.name,
          error_message: error.message
        )
      end

      def base_event(kind, step, execution)
        {
          event: kind,
          step_name: step.name,
          step_type: step.type,
          workflow_id: execution.workflow_id,
          node_path: Array(execution.node_path),
          attempt: execution.attempt,
          depth: execution.depth,
          parallel: execution.parallel
        }
      end

      def log(event)
        @logger.call(event)
      end
    end
  end
end
