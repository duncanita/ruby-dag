# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # The unit of data the forked child of the Processes strategy ships
      # back to the parent over its pipe. Replaces what used to be a bare
      # positional tuple so each call site reads named fields instead of
      # destructuring by index, and adding fields later does not silently
      # shift positions for downstream callers.
      ChildPayload = Data.define(:name, :result, :started_at, :finished_at, :duration_ms, :attempt_log) do
        # Append our middleware/passthrough trace entries onto the live
        # array the parent's Runner and TraceRecorder share with the Task.
        # Array#concat is a no-op when our log is empty, so callers don't
        # guard.
        def merge_into(task)
          task.attempt_log.concat(attempt_log)
        end

        # The 5-value tuple the Strategy contract requires the execute
        # block to receive (name, result, started_at, finished_at,
        # duration_ms). attempt_log is excluded because it's internal to
        # the Processes pipe and gets merged via #merge_into instead.
        def to_yield
          [name, result, started_at, finished_at, duration_ms]
        end
      end
    end
  end
end
