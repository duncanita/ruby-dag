# frozen_string_literal: true

require_relative "../test_helper"

class R2WorkflowRetryTest < Minitest::Test
  def test_resume_does_not_replace_explicit_workflow_retry
    storage = DAG::Adapters::Memory::Storage.new
    registry, counter = registry_with_failing_step(failures_before_success: 1)
    runtime_profile = DAG::RuntimeProfile[
      durability: :ephemeral,
      max_attempts_per_node: 1,
      max_workflow_retries: 1,
      event_bus_kind: :null,
      metadata: {}
    ]
    workflow_id = create_workflow(storage, flaky_definition, runtime_profile: runtime_profile)
    runner = build_runner(storage: storage, registry: registry)

    failed = runner.call(workflow_id)
    assert_equal :failed, failed.state
    assert_equal 1, counter[:value]

    assert_raises(DAG::StaleStateError) { runner.resume(workflow_id) }

    retried = runner.retry_workflow(workflow_id)
    assert_equal :completed, retried.state
    assert_equal 2, counter[:value]
  end

  private

  def flaky_definition
    DAG::Workflow::Definition.new.add_node(:a, type: :flaky)
  end
end
