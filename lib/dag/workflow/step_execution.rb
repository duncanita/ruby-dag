# frozen_string_literal: true

module DAG
  module Workflow
    StepExecution = Data.define(:workflow_id, :node_path, :attempt, :deadline, :depth, :parallel, :execution_store, :event_bus, :effective_max_sub_workflow_depth) do
      def initialize(workflow_id:, node_path:, attempt:, deadline:, depth:, parallel:, execution_store:, event_bus:, effective_max_sub_workflow_depth: nil)
        raise ArgumentError, "attempt must be >= 1" if attempt < 1
        raise ArgumentError, "depth must be >= 0" if depth < 0

        super
      end
    end
  end
end
