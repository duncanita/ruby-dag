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
          tasks.each { |task| yield(*run_task(task)) }
        end
      end
    end
  end
end
