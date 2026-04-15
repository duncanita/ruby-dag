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

      def ttl
        @ttl ||= normalized_ttl
      end

      def reusable_output_expired?(stored)
        return false unless ttl && stored[:saved_at]

        stored[:saved_at] <= (@clock.wall_now - ttl)
      end

      def ttl_expired_cause(name, stored)
        {
          code: :ttl_expired,
          message: "reusable output for step #{name} expired after schedule.ttl",
          saved_at: stored[:saved_at].utc.iso8601,
          ttl_seconds: ttl
        }
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

      def normalized_ttl
        raw = @step.config.dig(:schedule, :ttl)
        case raw
        when nil
          nil
        when Numeric
          raw
        else
          Float(raw)
        end
      end
    end
  end
end
