# frozen_string_literal: true

module DAG
  module Adapters
    module Stdlib
      class Clock
        include Ports::Clock

        def initialize
          freeze
        end

        def now = Time.now
        def now_ms = (Time.now.to_f * 1000).to_i
        def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
    end
  end
end
