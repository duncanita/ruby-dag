# frozen_string_literal: true

module DAG
  module Workflow
    class StepMiddleware
      def call(step, input, context:, execution:, next_step:)
        next_step.call(step, input, context: context, execution: execution)
      end
    end
  end
end
