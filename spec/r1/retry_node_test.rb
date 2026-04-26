# frozen_string_literal: true

require_relative "../test_helper"

class RetryNodeTest < Minitest::Test
  def test_retriable_node_succeeds_on_third_attempt
    storage = DAG::Adapters::Memory::Storage.new
    registry, _counter = registry_with_failing_step(failures_before_success: 2)
    runner = build_runner(storage: storage, registry: registry)

    definition = DAG::Workflow::Definition.new.add_node(:flaky, type: :flaky)
    workflow_id = create_workflow(storage, definition,
      runtime_profile: build_runtime_profile(max_attempts_per_node: 3))

    result = runner.call(workflow_id)
    assert_equal :completed, result.state
    assert_equal 3, storage.count_attempts(workflow_id: workflow_id, revision: 1, node_id: :flaky)
  end

  def test_retriable_node_exhausting_attempts_fails_workflow
    storage = DAG::Adapters::Memory::Storage.new
    registry, _counter = registry_with_failing_step(failures_before_success: 5)
    runner = build_runner(storage: storage, registry: registry)

    definition = DAG::Workflow::Definition.new.add_node(:flaky, type: :flaky)
    workflow_id = create_workflow(storage, definition,
      runtime_profile: build_runtime_profile(max_attempts_per_node: 3))

    result = runner.call(workflow_id)
    assert_equal :failed, result.state
    assert_equal 3, storage.count_attempts(workflow_id: workflow_id, revision: 1, node_id: :flaky)
  end

  private

  def build_runtime_profile(max_attempts_per_node:, max_workflow_retries: 0)
    DAG::RuntimeProfile[
      durability: :ephemeral,
      max_attempts_per_node: max_attempts_per_node,
      max_workflow_retries: max_workflow_retries,
      event_bus_kind: :null
    ]
  end
end
