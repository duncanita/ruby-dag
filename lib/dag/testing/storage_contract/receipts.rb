# frozen_string_literal: true

module DAG::Testing::StorageContract
  module Receipts
    include Helpers

    def test_contract_workflow_and_node_transitions_return_documented_receipts
      storage = build_contract_storage
      workflow_id = SecureRandom.uuid
      create_receipt = storage.create_workflow(
        id: workflow_id,
        initial_definition: contract_definition,
        initial_context: {seed: 1},
        runtime_profile: contract_runtime_profile
      )

      assert_receipt_keys %i[id current_revision], create_receipt
      assert_equal workflow_id, create_receipt.fetch(:id)
      assert_equal 1, create_receipt.fetch(:current_revision)

      transition_receipt = storage.transition_workflow_state(
        id: workflow_id,
        from: :pending,
        to: :running,
        event: contract_event(type: :workflow_started, workflow_id: workflow_id)
      )

      assert_receipt_keys %i[id state event], transition_receipt
      assert_equal workflow_id, transition_receipt.fetch(:id)
      assert_equal :running, transition_receipt.fetch(:state)
      assert_equal transition_receipt.fetch(:event), storage.read_events(workflow_id: workflow_id).last

      eventless_workflow_id = contract_create_workflow(storage)
      eventless_transition_receipt = storage.transition_workflow_state(
        id: eventless_workflow_id,
        from: :pending,
        to: :running
      )
      assert_receipt_keys %i[id state event], eventless_transition_receipt
      assert_nil eventless_transition_receipt.fetch(:event)

      node_receipt = storage.transition_node_state(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        from: :pending,
        to: :running
      )

      assert_receipt_keys %i[workflow_id revision node_id state], node_receipt
      assert_equal workflow_id, node_receipt.fetch(:workflow_id)
      assert_equal 1, node_receipt.fetch(:revision)
      assert_equal :a, node_receipt.fetch(:node_id)
      assert_equal :running, node_receipt.fetch(:state)
    end

    def test_contract_revision_append_operations_return_documented_receipts
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      next_definition = contract_definition.add_node(:c, type: :passthrough).add_edge(:b, :c)

      append_receipt = storage.append_revision(
        id: workflow_id,
        parent_revision: 1,
        definition: next_definition,
        invalidated_node_ids: [:b],
        event: contract_event(type: :mutation_applied, workflow_id: workflow_id)
      )

      assert_receipt_keys %i[id revision event], append_receipt
      assert_equal workflow_id, append_receipt.fetch(:id)
      assert_equal 2, append_receipt.fetch(:revision)
      assert_equal :mutation_applied, append_receipt.fetch(:event).type

      eventless_workflow_id = contract_create_workflow(storage)
      eventless_receipt = storage.append_revision(
        id: eventless_workflow_id,
        parent_revision: 1,
        definition: next_definition,
        invalidated_node_ids: [],
        event: nil
      )
      assert_receipt_keys %i[id revision event], eventless_receipt
      assert_nil eventless_receipt.fetch(:event)

      guarded_workflow_id = contract_create_workflow(storage)
      guarded_receipt = storage.append_revision_if_workflow_state(
        id: guarded_workflow_id,
        allowed_states: [:pending],
        parent_revision: 1,
        definition: next_definition,
        invalidated_node_ids: [:b],
        event: contract_event(type: :mutation_applied, workflow_id: guarded_workflow_id)
      )

      assert_receipt_keys %i[id revision event], guarded_receipt
      assert_equal guarded_workflow_id, guarded_receipt.fetch(:id)
      assert_equal 2, guarded_receipt.fetch(:revision)
      assert_equal :mutation_applied, guarded_receipt.fetch(:event).type
    end

    def test_contract_workflow_retry_returns_documented_receipt
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

      retry_receipt = storage.prepare_workflow_retry(
        id: workflow_id,
        from: :failed,
        to: :pending,
        event: contract_event(type: :workflow_started, workflow_id: workflow_id)
      )

      assert_receipt_keys %i[id state reset workflow_retry_count event], retry_receipt
      assert_equal workflow_id, retry_receipt.fetch(:id)
      assert_equal :pending, retry_receipt.fetch(:state)
      assert_equal [:a], retry_receipt.fetch(:reset)
      assert_equal 1, retry_receipt.fetch(:workflow_retry_count)
      assert_equal retry_receipt.fetch(:event), storage.read_events(workflow_id: workflow_id).last
    end

    def test_contract_effect_completion_returns_documented_receipts
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      succeeded = contract_commit_waiting_effect(storage, workflow_id, :a, effect_key: "succeeded")
      storage.claim_ready_effects(limit: 1, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)

      success_receipt = storage.complete_effect_succeeded(
        effect_id: succeeded.id,
        owner_id: "worker-a",
        result: {ok: true},
        external_ref: "external-1",
        now_ms: 1_100
      )

      assert_receipt_keys %i[record released], success_receipt
      assert_equal :succeeded, success_receipt.fetch(:record).status
      assert_equal 1, success_receipt.fetch(:released).size
      assert_receipt_keys(
        %i[workflow_id revision node_id attempt_id released_at_ms],
        success_receipt.fetch(:released).first
      )

      failed = contract_commit_waiting_effect(storage, workflow_id, :b, effect_key: "failed")
      storage.claim_ready_effects(limit: 1, owner_id: "worker-b", lease_ms: 500, now_ms: 2_000)
      failure_receipt = storage.complete_effect_failed(
        effect_id: failed.id,
        owner_id: "worker-b",
        error: {code: :terminal},
        retriable: false,
        not_before_ms: nil,
        now_ms: 2_100
      )

      assert_receipt_keys %i[record released], failure_receipt
      assert_equal :failed_terminal, failure_receipt.fetch(:record).status
      assert_equal 1, failure_receipt.fetch(:released).size
      assert_receipt_keys(
        %i[workflow_id revision node_id attempt_id released_at_ms],
        failure_receipt.fetch(:released).first
      )
    end

    private

    def assert_receipt_keys(expected, receipt)
      assert_equal expected.sort, receipt.keys.sort
    end
  end
end
