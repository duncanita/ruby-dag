# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # Wraps a StepOutcome with the attempt_log that doesn't survive the
      # fork() boundary on its own — the parent's array reference is
      # disconnected from the child's, so the child marshals the post-run
      # log alongside the outcome.
      ProcessesPayload = Data.define(:outcome, :attempt_log)
    end
  end
end
