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
        return if lifecycle_payload?(result)

        event_bus = @event_bus || execution.event_bus
        return unless event_bus&.respond_to?(:publish)

        Array(step.config[:emit_events]).each do |event_config|
          next unless should_emit?(event_config, result)

          event_bus.publish(Event.new(
            name: event_config.fetch(:name),
            workflow_id: execution.workflow_id,
            node_path: execution.node_path,
            payload: event_payload(event_config, result),
            metadata: event_metadata(event_config, result),
            emitted_at: @clock.wall_now
          ))
        end
      end

      def should_emit?(event_config, result)
        condition = event_config[:if]
        return true if condition.nil?

        condition.call(result)
      end

      def event_payload(event_config, result)
        payload_builder = event_config[:payload]
        return result.value if payload_builder.nil?

        payload_builder.call(result)
      end

      def event_metadata(event_config, result)
        metadata_builder = event_config[:metadata]
        return {} if metadata_builder.nil?

        metadata_builder.call(result)
      end

      # Sub_workflow paused/waiting results carry magic-key payloads that
      # are Runner's internal protocol, not user-facing values. Mirrors
      # AttemptTraceMiddleware#lifecycle_payload?.
      def lifecycle_payload?(result)
        return false unless result.success? && result.value.is_a?(Hash)

        %i[waiting paused].include?(result.value[:__sub_workflow_status__])
      end
    end
  end
end
