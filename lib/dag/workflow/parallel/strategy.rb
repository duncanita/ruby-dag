# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # Abstract base for parallel-execution strategies.
      #
      # Subclasses must implement #execute(tasks) { |outcome| ... } where
      # `outcome` is a `StepOutcome` carrying the task name, the
      # DAG::Result the executor produced, and the wall-clock boundaries.
      # The block is called once per task in **completion order**, not
      # submission order. All five fields must be populated even on
      # failure (use the wall-clock at failure time and duration_ms = 0
      # if you don't have real timings).
      #
      # Subclasses MUST also declare a `STRATEGY_SYM` constant (`:threads` /
      # `:sequential` / `:processes`) so `run_task` can stamp it into error
      # payloads without re-deriving it from the class name on every call.
      #
      # `max_parallelism` is a soft cap — most strategies window the in-flight
      # set down to that number; Sequential ignores it (it's always 1).
      class Strategy
        attr_reader :max_parallelism

        def initialize(max_parallelism:, clock: Clock.new)
          raise ArgumentError, "max_parallelism must be >= 1" if max_parallelism < 1

          @max_parallelism = max_parallelism
          @clock = clock
        end

        def execute(tasks, &block)
          raise NotImplementedError, "#{self.class} must implement #execute"
        end

        def name = self.class::STRATEGY_SYM

        # The single place that stamps timings, rescues attempt errors into a
        # Failure, and enforces the DAG::Result contract — so every strategy
        # produces identical trace shape and identical error shape.
        def run_task(task)
          strategy_sym = name
          started_at = @clock.monotonic_now
          result =
            begin
              raw = task.attempt.call
              if raw.is_a?(Result)
                raw
              else
                Failure.new(error: {
                  code: :step_bad_return,
                  message: "step #{task.name} returned #{raw.class} instead of a DAG::Result. " \
                           "Wrap the value in DAG::Success.new(value: ...) or DAG::Failure.new(error: ...).",
                  returned_class: raw.class.name,
                  strategy: strategy_sym
                })
              end
            rescue => e
              Result.exception_failure(:step_raised, e,
                message: "step #{task.name} raised: #{e.message}",
                strategy: strategy_sym)
            end
          finished_at = @clock.monotonic_now
          duration_ms = ((finished_at - started_at) * 1000).round(2)
          StepOutcome.new(name: task.name, result: result,
            started_at: started_at, finished_at: finished_at, duration_ms: duration_ms)
        end
      end
    end
  end
end
