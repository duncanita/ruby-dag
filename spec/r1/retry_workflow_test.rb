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

  def test_retry_workflow_uses_prepare_as_the_failed_to_pending_boundary
    storage_class = Class.new(DAG::Adapters::Memory::Storage) do
      def transition_workflow_state(id:, from:, to:, event: nil)
        if from == :failed && to == :pending
          raise "retry transition must happen inside prepare_workflow_retry"
        end

        super
      end
    end
    storage = storage_class.new
    registry, _counter = registry_with_failing_step(failures_before_success: 1)
    runner = build_runner(storage: storage, registry: registry)

    definition = DAG::Workflow::Definition.new.add_node(:flaky, type: :flaky)
    workflow_id = create_workflow(storage, definition,
      runtime_profile: profile(max_attempts_per_node: 1, max_workflow_retries: 1))

    assert_equal :failed, runner.call(workflow_id).state
    assert_equal :completed, runner.retry_workflow(workflow_id).state
  end

  def test_crash_after_prepare_workflow_retry_leaves_no_split_retry_state
    storage = DAG::Adapters::Memory::CrashableStorage.new(
      crash_on: {method: :prepare_workflow_retry, after: true, from: :failed, to: :pending}
    )
    registry, _counter = registry_with_failing_step(failures_before_success: 2)
    runner = build_runner(storage: storage, registry: registry)

    definition = DAG::Workflow::Definition.new.add_node(:flaky, type: :flaky)
    workflow_id = create_workflow(storage, definition,
      runtime_profile: profile(max_attempts_per_node: 1, max_workflow_retries: 2))

    assert_equal :failed, runner.call(workflow_id).state
    assert_raises(DAG::Adapters::Memory::SimulatedCrash) { runner.retry_workflow(workflow_id) }

    healthy_storage = storage.snapshot_to_healthy
    workflow = healthy_storage.load_workflow(id: workflow_id)
    assert_equal :pending, workflow[:state]
    assert_equal 1, workflow[:workflow_retry_count]
    assert_equal :pending, node_state(healthy_storage, workflow_id, :flaky)
  end

  def test_retry_does_not_overwrite_aborted_attempt_records
    storage = DAG::Adapters::Memory::Storage.new
    registry, _counter = registry_with_failing_step(failures_before_success: 4)
    runner = build_runner(storage: storage, registry: registry)

    definition = DAG::Workflow::Definition.new.add_node(:flaky, type: :flaky)
    workflow_id = create_workflow(storage, definition,
      runtime_profile: profile(max_attempts_per_node: 2, max_workflow_retries: 5))

    runner.call(workflow_id)
    runner.retry_workflow(workflow_id)
    runner.retry_workflow(workflow_id)

    attempts = storage.list_attempts(workflow_id: workflow_id, node_id: :flaky)
    attempt_ids = attempts.map { |a| a[:attempt_id] }
    assert_equal attempt_ids.size, attempt_ids.uniq.size, "attempt_ids must be unique across retries"
    aborted = attempts.count { |a| a[:state] == :aborted }
    assert aborted >= 1, "expected at least one :aborted attempt to survive retry"
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
