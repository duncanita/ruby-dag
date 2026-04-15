# frozen_string_literal: true

require_relative "test_helper"

class StepExecutionTest < Minitest::Test
  def test_rejects_attempts_below_one
    error = assert_raises(ArgumentError) do
      DAG::Workflow::StepExecution.new(
        workflow_id: "wf-1",
        node_path: [:build],
        attempt: 0,
        deadline: nil,
        depth: 0,
        parallel: :sequential,
        execution_store: nil,
        event_bus: nil
      )
    end

    assert_equal "attempt must be >= 1", error.message
  end

  def test_rejects_negative_depth
    error = assert_raises(ArgumentError) do
      DAG::Workflow::StepExecution.new(
        workflow_id: "wf-1",
        node_path: [:build],
        attempt: 1,
        deadline: nil,
        depth: -1,
        parallel: :sequential,
        execution_store: nil,
        event_bus: nil
      )
    end

    assert_equal "depth must be >= 0", error.message
  end
end
