# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # The five-field tuple every Strategy yields once per task: the task
      # name, the DAG::Result the executor produced, and the wall-clock
      # boundaries the trace records. Replaces the bare positional tuple
      # threaded through Strategy → Runner → TaskCompletionHandler /
      # TraceRecorder so call sites read named fields and adding a sixth
      # field doesn't ripple as silent index shifts.
      StepOutcome = Data.define(:name, :result, :started_at, :finished_at, :duration_ms)
    end
  end
end
