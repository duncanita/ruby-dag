# frozen_string_literal: true

module DAG::Testing::StorageContract
  module Retry
    include Helpers

    def test_contract_prepare_workflow_retry_resets_failed_nodes_attempts_and_appends_event
      storage = build_contract_storage
      workflow_id = contract_create_workflow(
        storage,
        runtime_profile: contract_runtime_profile(max_workflow_retries: 1)
      )
      attempt_id = contract_begin_attempt(storage, workflow_id, :a)
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Failure[error: {code: :boom}, retriable: false],
        node_state: :failed,
        event: contract_event(type: :node_failed, workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
      )
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :failed)
      event = contract_event(type: :workflow_started, workflow_id: workflow_id)

      result = storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending, event: event)

      assert_equal :pending, result.fetch(:state)
      assert_equal [:a], result.fetch(:reset)
      assert_equal 1, result.fetch(:workflow_retry_count)
      assert_equal result.fetch(:event), storage.read_events(workflow_id: workflow_id).last
      assert_equal :pending, storage.load_workflow(id: workflow_id).fetch(:state)
      assert_equal :pending, storage.load_node_states(workflow_id: workflow_id, revision: 1).fetch(:a)
      assert_equal :aborted, storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).first.fetch(:state)
      assert_equal 0, storage.count_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
    end

    def test_contract_prepare_workflow_retry_budget_failure_is_atomic
      storage = build_contract_storage
      workflow_id = contract_create_workflow(
        storage,
        runtime_profile: contract_runtime_profile(max_workflow_retries: 1)
      )
      first_attempt_id = contract_begin_attempt(storage, workflow_id, :a)
      storage.commit_attempt(
        attempt_id: first_attempt_id,
        result: DAG::Failure[error: {code: :boom}, retriable: false],
        node_state: :failed,
        event: contract_event(type: :node_failed, workflow_id: workflow_id, node_id: :a, attempt_id: first_attempt_id)
      )
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :failed)
      storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :failed)
      events_before = storage.read_events(workflow_id: workflow_id)

      assert_raises(DAG::WorkflowRetryExhaustedError) do
        storage.prepare_workflow_retry(
          id: workflow_id,
          from: :failed,
          to: :pending,
          event: contract_event(type: :workflow_started, workflow_id: workflow_id)
        )
      end

      assert_equal :failed, storage.load_workflow(id: workflow_id).fetch(:state)
      assert_equal 1, storage.load_workflow(id: workflow_id).fetch(:workflow_retry_count)
      assert_equal events_before, storage.read_events(workflow_id: workflow_id)
    end
  end
end
