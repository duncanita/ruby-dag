# frozen_string_literal: true

require_relative "test_helper"

class RunResultTest < Minitest::Test
  def test_rejects_unknown_status
    error = assert_raises(ArgumentError) do
      DAG::Workflow::RunResult.new(
        status: :nope,
        workflow_id: nil,
        outputs: {},
        trace: [],
        error: nil,
        waiting_nodes: []
      )
    end

    assert_match(/invalid run result status/, error.message)
  end

  def test_rejects_error_outside_failed_status
    error = assert_raises(ArgumentError) do
      DAG::Workflow::RunResult.new(
        status: :completed,
        workflow_id: nil,
        outputs: {},
        trace: [],
        error: {failed_node: :a},
        waiting_nodes: []
      )
    end

    assert_match(/only valid for failed workflows/, error.message)
  end

  def test_rejects_waiting_nodes_outside_waiting_status
    error = assert_raises(ArgumentError) do
      DAG::Workflow::RunResult.new(
        status: :completed,
        workflow_id: nil,
        outputs: {},
        trace: [],
        error: nil,
        waiting_nodes: [:a]
      )
    end

    assert_match(/only valid for waiting workflows/, error.message)
  end
end
