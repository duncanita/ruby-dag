# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # Thread-pool strategy. Runs tasks on `Thread`s with a windowed pool
      # capped at `max_parallelism`.
      #
      # Thread parallelism is the right default for the dominant ruby-dag
      # workload (`exec` / `ruby_script` / `file_*` steps), all of which
      # release the GVL during their syscalls. CPU-bound pure-Ruby work in a
      # `:ruby` step still serializes through the GVL, but is not the typical
      # case for this library.
      #
      # Threads share memory, so step results don't need to be Ractor-shareable
      # or Marshal-able. Any object the step returns is fine.
      class Threads < Strategy
        def execute(tasks)
          queue = Queue.new
          pending = tasks.dup
          in_flight = 0
          completed = 0

          while completed < tasks.size
            while in_flight < @max_parallelism && !pending.empty?
              spawn_worker(pending.shift, queue)
              in_flight += 1
            end

            name, result, started_at, finished_at, duration_ms = queue.pop
            yield name, result, started_at, finished_at, duration_ms
            in_flight -= 1
            completed += 1
          end
        end

        private

        # Runs `task` in a fresh Thread and pushes exactly one result tuple to
        # `queue` — no matter what. The structure is:
        #
        #   begin:    run the step, catch StandardError → Failure
        #   ensure:   if we never pushed (step raised below StandardError, or
        #             something exploded in our bookkeeping) push a synthetic
        #             failure so the parent's `queue.pop` cannot deadlock.
        #
        # This replaces an earlier `rescue Exception` boundary — same contract
        # (push exactly once, never leave the parent hanging), less rescue.
        def spawn_worker(task, queue)
          Thread.new do
            # The strategy itself surfaces worker death as a Failure (see the
            # `ensure` below), so Ruby's default thread-death warning would be
            # redundant double reporting.
            Thread.current.report_on_exception = false
            pushed = false
            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result =
              begin
                task.executor_class.new.call(task.step, task.input)
              rescue => e
                Failure.new(error: "Threads strategy: step #{task.name} raised #{e.class}: #{e.message}")
              end
            finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_ms = ((finished_at - started_at) * 1000).round(2)

            queue.push([task.name, result, started_at, finished_at, duration_ms])
            pushed = true
          ensure
            unless pushed
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              failure = Failure.new(error: "Threads strategy: worker for #{task.name} died without producing a result")
              queue.push([task.name, failure, now, now, 0.0])
            end
          end
        end
      end
    end
  end
end
