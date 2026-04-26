# frozen_string_literal: true

require_relative "../test_helper"

class RetryWorkflowTest < Minitest::Test
  def test_retry_workflow_resets_failed_node_when_budget_remains
    storage = DAG::Adapters::Memory::Storage.new
    registry, counter = registry_with_failing_step(failures_before_success: 4)
    runner = build_runner(storage: storage, registry: registry)

    definition = DAG::Workflow::Definition.new.add_node(:flaky, type: :flaky)
    workflow_id = create_workflow(storage, definition,
      runtime_profile: profile(max_attempts_per_node: 2, max_workflow_retries: 5))

    first = runner.call(workflow_id)
    assert_equal :failed, first.state
    assert_equal 2, counter[:value]

    second = runner.retry_workflow(workflow_id)
    assert_equal :failed, second.state
    assert_equal 4, counter[:value]

    third = runner.retry_workflow(workflow_id)
    assert_equal :completed, third.state
    assert_equal 5, counter[:value]
  end

  def test_retry_workflow_raises_when_budget_exhausted
    storage = DAG::Adapters::Memory::Storage.new
    registry, _counter = registry_with_failing_step(failures_before_success: 100)
    runner = build_runner(storage: storage, registry: registry)

    definition = DAG::Workflow::Definition.new.add_node(:flaky, type: :flaky)
    workflow_id = create_workflow(storage, definition,
      runtime_profile: profile(max_attempts_per_node: 1, max_workflow_retries: 1))

    runner.call(workflow_id)
    runner.retry_workflow(workflow_id)
    assert_raises(DAG::WorkflowRetryExhaustedError) { runner.retry_workflow(workflow_id) }
  end

  def test_retry_workflow_only_valid_when_failed
    storage = DAG::Adapters::Memory::Storage.new
    runner = build_runner(storage: storage)
    workflow_id = create_workflow(storage, simple_definition,
      runtime_profile: profile(max_attempts_per_node: 1, max_workflow_retries: 1))

    runner.call(workflow_id)
    assert_raises(DAG::StaleStateError) { runner.retry_workflow(workflow_id) }
  end

  private

  def profile(max_attempts_per_node:, max_workflow_retries:)
    DAG::RuntimeProfile[
      durability: :ephemeral,
      max_attempts_per_node: max_attempts_per_node,
      max_workflow_retries: max_workflow_retries,
      event_bus_kind: :null
    ]
  end
end
