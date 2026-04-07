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
      # set down to that number; Sequential ignores it (it's always 1).
      class Strategy
        attr_reader :max_parallelism

        def initialize(max_parallelism:)
          raise ArgumentError, "max_parallelism must be >= 1" if max_parallelism < 1

          @max_parallelism = max_parallelism
        end

        def execute(tasks, &block)
          raise NotImplementedError, "#{self.class} must implement #execute"
        end

        # Strategy display name for warnings and trace metadata.
        def name
          self.class.name.split("::").last.downcase.to_sym
        end

        # Runs one task and returns the 5-tuple `[name, result, started_at,
        # finished_at, duration_ms]` that `#execute` is contracted to yield.
        # This is the ONE place that stamps the monotonic clock and rescues
        # step errors into a `Failure`, so every strategy produces identical
        # trace shape and identical error-message prefixes.
        #
        # Inherited dispatch carries the subclass identity: when a `Threads`
        # instance calls `self.class.run_task(task)`, the inherited class
        # method runs with `self == Threads`, so the error prefix says
        # "Threads strategy: ..." with no parameter passing required.
        def self.run_task(task)
          label = name.split("::").last
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result =
            begin
              task.executor_class.new.call(task.step, task.input)
            rescue => e
              Failure.new(error: "#{label} strategy: step #{task.name} raised #{e.class}: #{e.message}")
            end
          finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          duration_ms = ((finished_at - started_at) * 1000).round(2)
          [task.name, result, started_at, finished_at, duration_ms]
        end

        def run_task(task)
          self.class.run_task(task)
        end
      end
    end
  end
end
