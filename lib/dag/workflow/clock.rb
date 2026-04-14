# frozen_string_literal: true

module DAG
  module Workflow
    class Clock
      def wall_now = Time.now.utc
      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
