# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # The unit of data the forked child of the Processes strategy ships
      # back to the parent over its pipe. Wraps the StepOutcome the
      # Strategy contract yields together with the attempt_log that
      # otherwise wouldn't survive the fork() boundary.
      ChildPayload = Data.define(:outcome, :attempt_log) do
        # Append our middleware/passthrough trace entries onto the live
        # array the parent's Runner and TraceRecorder share with the Task.
        # Array#concat is a no-op when our log is empty, so callers don't
        # guard.
        def merge_into(task)
          task.attempt_log.concat(attempt_log)
        end
      end
    end
  end
end
