# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class SubWorkflow
        def call(_step, _input, **_kwargs)
          Failure.new(error: {
            code: :sub_workflow_runner_required,
            message: "sub_workflow steps are executed by DAG::Workflow::Runner internals"
          })
        end
      end
    end
  end
end
