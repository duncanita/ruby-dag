# frozen_string_literal: true

module DAG
  module Workflow
    # Strategy-based parallel execution. The Runner builds Tasks for the
    # runnable steps in a layer (after run_if filtering) and hands them to a
    # Strategy. Each strategy decides how to run them concurrently — on the
    # main thread, in a Thread pool, or in forked child processes.
    #
    # The Runner stays out of concurrency concerns; the Strategy stays out of
    # graph + trace concerns. Strategies only see Tasks and yield results.
    module Parallel
      # Unit of work for a strategy. The strategy must:
      #   1. Call `executor_class.new.call(step, input)`
      #   2. Yield back the resulting Result with timing info
      #
      # `input_keys` is carried so the Runner can build the trace entry without
      # needing to re-resolve inputs after the strategy returns.
      Task = Data.define(:name, :step, :input, :executor_class, :input_keys)
    end
  end
end
