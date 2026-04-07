# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # Runs tasks one at a time on the calling thread. Used as the default
      # when `parallel: false` is requested, and as the per-layer fallback
      # when a more aggressive strategy can't handle the steps in a layer.
      #
      # `max_parallelism` is ignored — sequential is always 1.
      class Sequential < Strategy
        def initialize(max_parallelism: 1)
          super(max_parallelism: 1)
        end

        def execute(tasks)
          tasks.each do |task|
            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result =
              begin
                task.executor_class.new.call(task.step, task.input)
              rescue => e
                Failure.new(error: "Sequential strategy: step #{task.name} raised #{e.class}: #{e.message}")
              end
            finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_ms = ((finished_at - started_at) * 1000).round(2)

            yield task.name, result, started_at, finished_at, duration_ms
          end
        end
      end
    end
  end
end
