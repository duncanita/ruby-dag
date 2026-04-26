# frozen_string_literal: true

require_relative "../test_helper"

class FanOutFanInTest < Minitest::Test
  def test_d_runs_after_both_branches
    storage = DAG::Adapters::Memory::Storage.new
    event_bus = DAG::Adapters::Memory::EventBus.new
    runner = build_runner(storage: storage, event_bus: event_bus)

    workflow_id = create_workflow(storage, fan_out_fan_in(:a, [:b, :c], :d), initial_context: {seed: 42})
    result = runner.call(workflow_id)

    assert_equal :completed, result.state

    commits = event_bus.events.select { |e| e.type == :node_committed }.map(&:node_id)
    d_index = commits.index(:d)
    assert d_index, "d must commit"
    assert commits.index(:b) < d_index
    assert commits.index(:c) < d_index
  end

  def test_branch_order_is_deterministic_topological
    storage = DAG::Adapters::Memory::Storage.new
    event_bus = DAG::Adapters::Memory::EventBus.new
    runner = build_runner(storage: storage, event_bus: event_bus)

    workflow_id = create_workflow(storage, fan_out_fan_in(:a, [:c, :b], :d))
    runner.call(workflow_id)

    commits = event_bus.events.select { |e| e.type == :node_committed }.map(&:node_id)
    assert_equal [:a, :b, :c, :d], commits, "ASCII tie-break must put :b before :c regardless of insertion order"
  end
end
