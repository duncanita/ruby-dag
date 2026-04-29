# frozen_string_literal: true

module DAG
  # Default kernel adapters bundled with `ruby-dag`. The `Stdlib` family
  # uses only the Ruby standard library; `Memory` adapters implement the
  # in-memory single-process kernel state; `Null` adapters drop input.
  # @api public
  module Adapters
    # Adapters that wrap the Ruby standard library.
    # @api public
    module Stdlib
      # `DAG::Ports::Clock` adapter backed by `Time.now` and
      # `Process.clock_gettime`. Frozen on construction.
      # @api public
      class Clock
        include Ports::Clock

        def initialize
          freeze
        end

        # @return [Time] wall-clock time
        def now = Time.now

        # @return [Integer] wall-clock time in milliseconds since epoch
        def now_ms = (Time.now.to_f * 1000).to_i

        # @return [Integer] monotonic milliseconds since an arbitrary epoch
        def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
    end
  end
end
