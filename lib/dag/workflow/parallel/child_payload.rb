# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # The unit of data the forked child of the Processes strategy ships
      # back to the parent over its pipe. Replaces what used to be a bare
      # positional tuple so each call site reads named fields instead of
      # destructuring by index, and adding fields later does not silently
      # shift positions for downstream callers.
      ChildPayload = Data.define(:name, :result, :started_at, :finished_at, :duration_ms, :attempt_log)
    end
  end
end
