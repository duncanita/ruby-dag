# frozen_string_literal: true

module DAG
  module Workflow
    class EventMiddleware < StepMiddleware
      def initialize(event_bus: nil, clock: Clock.new)
        @event_bus = event_bus
        @clock = clock
      end

      def call(step, input, context:, execution:, next_step:)
        result = next_step.call(step, input, context: context, execution: execution)
        emit_events(step, execution, result)
        result
      end

      private

      def emit_events(step, execution, result)
        return unless result.success?

        event_bus = @event_bus || execution.event_bus
        return unless event_bus&.respond_to?(:publish)

        Array(step.config[:emit_events]).each do |event_config|
          next unless should_emit?(event_config, result)

          event_bus.publish(Event.new(
            name: event_config.fetch(:name),
            workflow_id: execution.workflow_id,
            node_path: execution.node_path,
            payload: result.value,
            emitted_at: @clock.wall_now
          ))
        end
      end

      def should_emit?(event_config, result)
        condition = event_config[:if]
        return true if condition.nil?

        condition.call(result)
      end
    end
  end
end
