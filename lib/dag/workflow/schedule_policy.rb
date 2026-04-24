# frozen_string_literal: true

require "time"

module DAG
  module Workflow
    class SchedulePolicy
      def initialize(step, clock:)
        @step = step
        @clock = clock
      end

      # Lazy so a malformed `schedule.not_before` surfaces at the admission
      # site (`LayerAdmitter#call`) where it becomes a step-level failure,
      # not at Runner construction time.
      def not_before
        return @not_before if defined?(@not_before)
        @not_before = normalized_time(:not_before)
      end

      def not_after
        return @not_after if defined?(@not_after)
        @not_after = normalized_time(:not_after)
      end

      def ttl
        return @ttl if defined?(@ttl)
        @ttl = normalized_ttl
      end

      def waiting?
        return false if impossible_window?
        not_before && @clock.wall_now < not_before
      end

      def expired?
        not_after && @clock.wall_now > not_after
      end

      def impossible_window?
        not_before && not_after && not_before > not_after
      end

      def deadline_exceeded_result(name)
        Failure.new(error: {
          code: :deadline_exceeded,
          message: "step #{name} missed schedule.not_after #{not_after.utc.iso8601}",
          not_after: not_after.utc.iso8601
        })
      end

      def impossible_window_result(name)
        Failure.new(error: {
          code: :invalid_schedule_window,
          message: "step #{name} has schedule.not_before #{not_before.utc.iso8601} after schedule.not_after #{not_after.utc.iso8601}: impossible window",
          not_before: not_before.utc.iso8601,
          not_after: not_after.utc.iso8601
        })
      end

      def reusable_output_expired?(stored)
        return false if ttl.nil?
        return true if ttl <= 0
        return false unless stored[:saved_at]

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
