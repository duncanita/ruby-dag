# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # What every Strategy yields once per task: the routing key (name),
      # the DAG::Result the executor produced, and the wall-clock
      # boundaries the trace records.
      StepOutcome = Data.define(:name, :result, :started_at, :finished_at, :duration_ms)
    end
  end
end
