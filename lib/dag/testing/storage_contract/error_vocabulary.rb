# frozen_string_literal: true

module DAG::Testing::StorageContract
  module ErrorVocabulary
    include Helpers

    def test_contract_uses_standard_workflow_storage_error_classes
      storage = build_contract_storage

      assert_contract_error(DAG::UnknownWorkflowError) { storage.load_workflow(id: "missing") }

      workflow_id = contract_create_workflow(storage)
      assert_contract_error(DAG::StaleStateError) do
        storage.transition_workflow_state(id: workflow_id, from: :running, to: :completed)
      end

      next_definition = contract_definition.add_node(:c, type: :passthrough).add_edge(:b, :c)
      assert_contract_error(DAG::StaleRevisionError) do
        storage.append_revision(
          id: workflow_id,
          parent_revision: 99,
          definition: next_definition,
          invalidated_node_ids: [],
          event: contract_event(type: :mutation_applied, workflow_id: workflow_id)
        )
      end

      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
      assert_contract_error(DAG::ConcurrentMutationError) do
        storage.append_revision_if_workflow_state(
          id: workflow_id,
          allowed_states: %i[paused waiting],
          parent_revision: 1,
          definition: next_definition,
          invalidated_node_ids: [:b],
          event: contract_event(type: :mutation_applied, workflow_id: workflow_id)
        )
      end
    end

    def test_contract_uses_standard_retry_and_effect_error_classes
      storage = build_contract_storage
      retry_workflow_id = contract_create_workflow(
        storage,
        runtime_profile: contract_runtime_profile(max_workflow_retries: 0)
      )
      attempt_id = contract_begin_attempt(storage, retry_workflow_id, :a)
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Failure[error: {code: :boom}, retriable: false],
        node_state: :failed,
        event: contract_event(
          type: :node_failed,
          workflow_id: retry_workflow_id,
          node_id: :a,
          attempt_id: attempt_id
        )
      )
      storage.transition_workflow_state(id: retry_workflow_id, from: :pending, to: :failed)

      assert_contract_error(DAG::WorkflowRetryExhaustedError) do
        storage.prepare_workflow_retry(id: retry_workflow_id, from: :failed, to: :pending)
      end

      assert_contract_error(DAG::Effects::UnknownEffectError) do
        storage.mark_effect_succeeded(
          effect_id: "missing",
          owner_id: "worker-a",
          result: {ok: true},
          external_ref: nil,
          now_ms: 1_000
        )
      end

      lease_workflow_id = contract_create_workflow(storage)
      leased = contract_commit_waiting_effect(storage, lease_workflow_id, :a, effect_key: "leased")
      storage.claim_ready_effects(limit: 1, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)

      assert_contract_error(DAG::Effects::StaleLeaseError) do
        storage.mark_effect_succeeded(
          effect_id: leased.id,
          owner_id: "worker-b",
          result: {ok: true},
          external_ref: nil,
          now_ms: 1_100
        )
      end
    end

    def test_contract_uses_standard_idempotency_conflict_error_class
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      first_attempt_id = contract_begin_attempt(storage, workflow_id, :a)
      first_effect = contract_prepared_effect(
        workflow_id: workflow_id,
        attempt_id: first_attempt_id,
        effect_key: "same-ref"
      )
      storage.commit_attempt(
        attempt_id: first_attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: first_attempt_id),
        effects: [first_effect]
      )
      first_record = storage.list_effects_for_attempt(attempt_id: first_attempt_id).first
      storage.claim_ready_effects(limit: 1, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)
      storage.complete_effect_succeeded(
        effect_id: first_record.id,
        owner_id: "worker-a",
        result: {ok: true},
        external_ref: nil,
        now_ms: 1_100
      )

      second_attempt_id = contract_begin_attempt(storage, workflow_id, :a, attempt_number: 2)
      conflicting_effect = contract_prepared_effect(
        workflow_id: workflow_id,
        attempt_id: second_attempt_id,
        effect_key: "same-ref",
        payload_fingerprint: "different"
      )

      assert_contract_error(DAG::Effects::IdempotencyConflictError) do
        storage.commit_attempt(
          attempt_id: second_attempt_id,
          result: DAG::Waiting[reason: :effect_pending],
          node_state: :waiting,
          event: contract_event(
            type: :node_waiting,
            workflow_id: workflow_id,
            node_id: :a,
            attempt_id: second_attempt_id
          ),
          effects: [conflicting_effect]
        )
      end
    end

    private

    def assert_contract_error(error_class)
      error = assert_raises(error_class) { yield }
      assert_kind_of DAG::Error, error
    end
  end
end
