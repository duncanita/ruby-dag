# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # Abstract base for parallel-execution strategies.
      #
      # Subclasses must implement #execute(tasks) { |name, result, started_at,
      # finished_at, duration_ms| ... }. The block is called once per task in
      # **completion order**, not submission order. All five values must be
      # present even on failure (use the wall-clock at failure time and
      # duration_ms = 0 if you don't have real timings).
      #
      # `max_parallelism` is a soft cap — most strategies window the in-flight
      # set down to that number, but Sequential ignores it (it's always 1) and
      # Ractors honor it best-effort (see ractors.rb for why).
      class Strategy
        attr_reader :max_parallelism

        # Whether this strategy is considered experimental — i.e. it carries
        # known limitations that make it unsuitable as a default, even though
        # it ships. Overridden by individual strategies. The Runner uses this
        # to emit a one-time warning the first time an experimental strategy
        # is instantiated in a process.
        def self.experimental? = false

        def initialize(max_parallelism:)
          raise ArgumentError, "max_parallelism must be >= 1" if max_parallelism < 1

          @max_parallelism = max_parallelism
        end

        def execute(tasks, &block)
          raise NotImplementedError, "#{self.class} must implement #execute"
        end

        # Whether this strategy can run the given Steps. Defaults to true; the
        # Ractors strategy overrides to lazily preflight each step (calling
        # `Ractor.make_shareable` and caching the result by step identity) and
        # returns false if any step can't be made shareable. The Runner uses
        # this to fall back to Sequential per-layer when the primary strategy
        # can't handle the workload.
        #
        # This is the only Ractor-related interface on a Strategy. Step itself
        # is pure data and knows nothing about Ractors — anything to do with
        # shareability lives inside the Ractors strategy.
        def supports?(_steps)
          true
        end

        # Strategy display name for warnings and trace metadata.
        def name
          self.class.name.split("::").last.downcase.to_sym
        end
      end
    end
  end
end
