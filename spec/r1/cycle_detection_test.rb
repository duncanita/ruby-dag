# frozen_string_literal: true

require_relative "../test_helper"

class CycleDetectionTest < Minitest::Test
  def test_self_loop_raises_cycle_error_with_offending_edge
    error = assert_raises(DAG::CycleError) do
      DAG::Workflow::Definition.new.add_node(:a, type: :passthrough).add_edge(:a, :a)
    end
    assert_match(/a/, error.message)
  end

  def test_back_edge_raises_cycle_error_naming_offending_edge
    base = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_edge(:a, :b)

    error = assert_raises(DAG::CycleError) { base.add_edge(:b, :a) }
    assert_match(/a/, error.message)
    assert_match(/b/, error.message)
  end
end
