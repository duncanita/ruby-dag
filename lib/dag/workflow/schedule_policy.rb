# frozen_string_literal: true

require "time"

module DAG
  module Workflow
    class SchedulePolicy
      def initialize(step, clock:)
        @step = step
        @clock = clock
      end

      def waiting?
        not_before && @clock.wall_now < not_before
      end

      def expired?
        not_after && @clock.wall_now > not_after
      end

      def deadline_exceeded_result(name)
        Failure.new(error: {
          code: :deadline_exceeded,
          message: "step #{name} missed schedule.not_after #{not_after.utc.iso8601}",
          not_after: not_after.utc.iso8601
        })
      end

      def not_before
        @not_before ||= normalized_time(:not_before)
      end

      def not_after
        @not_after ||= normalized_time(:not_after)
      end

      private

      def normalized_time(key)
        raw = @step.config.dig(:schedule, key)
        case raw
        when nil
          nil
        when Time
          raw
        else
          Time.parse(raw.to_s)
        end
      end
    end
  end
end
