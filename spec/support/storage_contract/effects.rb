# frozen_string_literal: true

module StorageContract
  module Effects
    include Helpers

    def test_contract_commit_attempt_persists_effects_atomically
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = begin_contract_attempt(storage, workflow_id, :a)
      effect = contract_prepared_effect(workflow_id: workflow_id, attempt_id: attempt_id)

      stamped = storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id),
        effects: [effect]
      )

      attempts = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
      assert_equal :waiting, attempts.first[:state]
      assert_equal :waiting, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
      assert_equal stamped, storage.read_events(workflow_id: workflow_id).last

      records = storage.list_effects_for_attempt(attempt_id: attempt_id)
      assert_equal 1, records.size
      assert_equal effect.ref, records.first.ref
      assert_equal :reserved, records.first.status
      assert records.first.blocking
      assert records.first.frozen?
      assert records.first.payload.frozen?
    end

    def test_contract_commit_attempt_effects_default_to_empty
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = begin_contract_attempt(storage, workflow_id, :a)

      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: :a, context_patch: {}],
        node_state: :committed,
        event: contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
      )

      assert_empty storage.list_effects_for_attempt(attempt_id: attempt_id)
      assert_empty storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a)
    end

    def test_contract_effect_reservation_is_idempotent_for_same_ref_and_fingerprint
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      first_attempt_id = begin_contract_attempt(storage, workflow_id, :a)
      first_effect = contract_prepared_effect(workflow_id: workflow_id, attempt_id: first_attempt_id)
      storage.commit_attempt(
        attempt_id: first_attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: first_attempt_id),
        effects: [first_effect]
      )

      first_record = storage.list_effects_for_attempt(attempt_id: first_attempt_id).first
      mark_effect_success(storage, first_record.id)
      storage.release_nodes_satisfied_by_effect(
        effect_id: first_record.id,
        now_ms: 1_700_000_000_010
      )
      second_attempt_id = begin_contract_attempt(storage, workflow_id, :a, attempt_number: 2)
      second_effect = contract_prepared_effect(workflow_id: workflow_id, attempt_id: second_attempt_id)

      storage.commit_attempt(
        attempt_id: second_attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: second_attempt_id),
        effects: [second_effect]
      )

      second_record = storage.list_effects_for_attempt(attempt_id: second_attempt_id).first
      assert_equal first_record.id, second_record.id
      assert_equal :succeeded, second_record.status
      assert_equal first_effect.payload_fingerprint, second_record.payload_fingerprint
    end

    def test_contract_effect_fingerprint_conflict_rolls_back_attempt_commit
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      first_attempt_id = begin_contract_attempt(storage, workflow_id, :a)
      storage.commit_attempt(
        attempt_id: first_attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: first_attempt_id),
        effects: [contract_prepared_effect(workflow_id: workflow_id, attempt_id: first_attempt_id)]
      )

      first_record = storage.list_effects_for_attempt(attempt_id: first_attempt_id).first
      mark_effect_success(storage, first_record.id)
      storage.release_nodes_satisfied_by_effect(effect_id: first_record.id, now_ms: 1_700_000_000_010)
      second_attempt_id = begin_contract_attempt(storage, workflow_id, :a, attempt_number: 2)
      conflicting = contract_prepared_effect(
        workflow_id: workflow_id,
        attempt_id: second_attempt_id,
        payload_fingerprint: "different"
      )
      events_before = storage.read_events(workflow_id: workflow_id)

      assert_raises(DAG::Effects::IdempotencyConflictError) do
        storage.commit_attempt(
          attempt_id: second_attempt_id,
          result: DAG::Waiting[reason: :effect_pending],
          node_state: :waiting,
          event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: second_attempt_id),
          effects: [conflicting]
        )
      end

      attempts = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
      failed_attempt = attempts.find { |attempt| attempt[:attempt_id] == second_attempt_id }
      assert_equal :running, failed_attempt[:state]
      assert_nil failed_attempt[:result]
      assert_equal :running, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
      assert_equal events_before, storage.read_events(workflow_id: workflow_id)
      assert_empty storage.list_effects_for_attempt(attempt_id: second_attempt_id)
    end

    def test_contract_failed_retriable_effect_is_claimed_only_when_due
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      effect = commit_waiting_effect(storage, workflow_id, :a)
      storage.claim_ready_effects(limit: 1, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)
      storage.mark_effect_failed(
        effect_id: effect.id,
        owner_id: "worker-a",
        error: {code: :retry},
        retriable: true,
        not_before_ms: 2_000,
        now_ms: 1_100
      )

      assert_empty storage.claim_ready_effects(limit: 1, owner_id: "worker-b", lease_ms: 500, now_ms: 1_999)

      claimed = storage.claim_ready_effects(limit: 1, owner_id: "worker-b", lease_ms: 500, now_ms: 2_000)
      assert_equal [effect.id], claimed.map(&:id)
      assert_equal "worker-b", claimed.first.lease_owner
    end

    def test_contract_claim_ready_effects_assigns_unique_leases
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      first_effect_id = commit_waiting_effect(storage, workflow_id, :a).id

      claimed = storage.claim_ready_effects(limit: 1, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)
      assert_equal [first_effect_id], claimed.map(&:id)
      assert_equal "worker-a", claimed.first.lease_owner
      assert_equal 1_500, claimed.first.lease_until_ms
      assert_equal :dispatching, claimed.first.status

      assert_empty storage.claim_ready_effects(limit: 1, owner_id: "worker-b", lease_ms: 500, now_ms: 1_100)
      assert_empty storage.claim_ready_effects(limit: 1, owner_id: "worker-b", lease_ms: 500, now_ms: 1_500)

      reclaimed = storage.claim_ready_effects(limit: 1, owner_id: "worker-b", lease_ms: 500, now_ms: 1_501)
      assert_equal [first_effect_id], reclaimed.map(&:id)
      assert_equal "worker-b", reclaimed.first.lease_owner
    end

    def test_contract_mark_effect_succeeded_requires_current_lease
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      effect = commit_waiting_effect(storage, workflow_id, :a)
      storage.claim_ready_effects(limit: 1, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)

      assert_raises(DAG::Effects::StaleLeaseError) do
        storage.mark_effect_succeeded(
          effect_id: effect.id,
          owner_id: "worker-b",
          result: {ok: true},
          external_ref: "external-1",
          now_ms: 1_100
        )
      end

      updated = storage.mark_effect_succeeded(
        effect_id: effect.id,
        owner_id: "worker-a",
        result: {ok: true},
        external_ref: "external-1",
        now_ms: 1_100
      )
      assert_equal :succeeded, updated.status
      assert updated.terminal?
      assert_equal({ok: true}, updated.result)
      assert_nil updated.lease_owner
      assert_nil updated.lease_until_ms
    end

    def test_contract_complete_effect_succeeded_releases_waiting_node_atomically
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      effect = commit_waiting_effect(storage, workflow_id, :a)
      storage.claim_ready_effects(limit: 1, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)

      completion = storage.complete_effect_succeeded(
        effect_id: effect.id,
        owner_id: "worker-a",
        result: {ok: true},
        external_ref: "external-1",
        now_ms: 1_100
      )

      assert_equal :succeeded, completion.fetch(:record).status
      assert_equal [{workflow_id: workflow_id, revision: 1, node_id: :a, attempt_id: effect.attempt_id, released_at_ms: 1_100}], completion.fetch(:released)
      assert_equal :pending, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
    end

    def test_contract_mark_effect_failed_requires_current_lease_and_sets_terminality
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      retriable = commit_waiting_effect(storage, workflow_id, :a, effect_key: "retry")
      terminal = commit_waiting_effect(storage, workflow_id, :b, effect_key: "terminal")

      storage.claim_ready_effects(limit: 2, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)

      assert_raises(DAG::Effects::StaleLeaseError) do
        storage.mark_effect_failed(
          effect_id: retriable.id,
          owner_id: "worker-b",
          error: {code: :late},
          retriable: true,
          not_before_ms: 2_000,
          now_ms: 1_100
        )
      end

      retriable_record = storage.mark_effect_failed(
        effect_id: retriable.id,
        owner_id: "worker-a",
        error: {code: :retry},
        retriable: true,
        not_before_ms: 2_000,
        now_ms: 1_100
      )
      terminal_record = storage.mark_effect_failed(
        effect_id: terminal.id,
        owner_id: "worker-a",
        error: {code: :terminal},
        retriable: false,
        not_before_ms: 2_000,
        now_ms: 1_100
      )

      assert_equal :failed_retriable, retriable_record.status
      refute retriable_record.terminal?
      assert_equal 2_000, retriable_record.not_before_ms
      assert_equal :failed_terminal, terminal_record.status
      assert terminal_record.terminal?
      assert_nil terminal_record.not_before_ms
    end

    def test_contract_complete_effect_failed_releases_only_terminal_failures
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      retriable = commit_waiting_effect(storage, workflow_id, :a, effect_key: "retry")
      terminal = commit_waiting_effect(storage, workflow_id, :b, effect_key: "terminal")
      storage.claim_ready_effects(limit: 2, owner_id: "worker-a", lease_ms: 500, now_ms: 1_000)

      retry_completion = storage.complete_effect_failed(
        effect_id: retriable.id,
        owner_id: "worker-a",
        error: {code: :retry},
        retriable: true,
        not_before_ms: 2_000,
        now_ms: 1_100
      )
      terminal_completion = storage.complete_effect_failed(
        effect_id: terminal.id,
        owner_id: "worker-a",
        error: {code: :terminal},
        retriable: false,
        not_before_ms: 2_000,
        now_ms: 1_100
      )

      assert_equal :failed_retriable, retry_completion.fetch(:record).status
      assert_empty retry_completion.fetch(:released)
      assert_equal :waiting, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
      assert_equal :failed_terminal, terminal_completion.fetch(:record).status
      assert_equal [{workflow_id: workflow_id, revision: 1, node_id: :b, attempt_id: terminal.attempt_id, released_at_ms: 1_100}], terminal_completion.fetch(:released)
      assert_equal :pending, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:b]
    end

    def test_contract_release_waiting_node_only_when_all_blocking_effects_terminal
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = begin_contract_attempt(storage, workflow_id, :a)
      first = contract_prepared_effect(workflow_id: workflow_id, attempt_id: attempt_id, effect_key: "first")
      second = contract_prepared_effect(workflow_id: workflow_id, attempt_id: attempt_id, effect_key: "second")
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id),
        effects: [first, second]
      )
      records = storage.list_effects_for_attempt(attempt_id: attempt_id)
      first_record = records.find { |record| record.key == "first" }
      second_record = records.find { |record| record.key == "second" }

      mark_effect_success(storage, first_record.id)
      assert_empty storage.release_nodes_satisfied_by_effect(effect_id: first_record.id, now_ms: 1_200)
      assert_equal :waiting, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]

      mark_effect_success(storage, second_record.id)
      released = storage.release_nodes_satisfied_by_effect(effect_id: second_record.id, now_ms: 1_300)
      assert_equal [{workflow_id: workflow_id, revision: 1, node_id: :a, attempt_id: attempt_id, released_at_ms: 1_300}], released
      assert_equal :pending, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
    end

    def test_contract_release_ignores_detached_effects_for_waiting_gate
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = begin_contract_attempt(storage, workflow_id, :a)
      blocking = contract_prepared_effect(workflow_id: workflow_id, attempt_id: attempt_id, effect_key: "blocking")
      detached = contract_prepared_effect(
        workflow_id: workflow_id,
        attempt_id: attempt_id,
        effect_key: "detached",
        blocking: false
      )
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id),
        effects: [blocking, detached]
      )
      blocking_record = storage.list_effects_for_attempt(attempt_id: attempt_id).find { |record| record.key == "blocking" }

      mark_effect_success(storage, blocking_record.id)
      released = storage.release_nodes_satisfied_by_effect(effect_id: blocking_record.id, now_ms: 1_200)

      assert_equal 1, released.size
      assert_equal :pending, storage.load_node_states(workflow_id: workflow_id, revision: 1)[:a]
    end

    private

    def begin_contract_attempt(storage, workflow_id, node_id, attempt_number: 1)
      storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: node_id,
        expected_node_state: :pending,
        attempt_number: attempt_number
      )
    end

    def contract_prepared_effect(
      workflow_id:,
      attempt_id:,
      node_id: :a,
      effect_type: "contract",
      effect_key: "effect",
      payload: {value: 1},
      payload_fingerprint: "fp-1",
      blocking: true,
      created_at_ms: 1_700_000_000_000
    )
      DAG::Effects::PreparedIntent[
        workflow_id: workflow_id,
        revision: 1,
        node_id: node_id,
        attempt_id: attempt_id,
        type: effect_type,
        key: effect_key,
        payload: payload,
        payload_fingerprint: payload_fingerprint,
        blocking: blocking,
        created_at_ms: created_at_ms
      ]
    end

    def commit_waiting_effect(storage, workflow_id, node_id, effect_key: "effect")
      attempt_id = begin_contract_attempt(storage, workflow_id, node_id)
      effect = contract_prepared_effect(workflow_id: workflow_id, attempt_id: attempt_id, node_id: node_id, effect_key: effect_key)
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: node_id, attempt_id: attempt_id),
        effects: [effect]
      )
      storage.list_effects_for_attempt(attempt_id: attempt_id).first
    end

    def mark_effect_success(storage, effect_id)
      storage.claim_ready_effects(limit: 1, owner_id: "worker-#{effect_id}", lease_ms: 500, now_ms: 1_000)
      storage.mark_effect_succeeded(
        effect_id: effect_id,
        owner_id: "worker-#{effect_id}",
        result: {ok: true},
        external_ref: "external-#{effect_id}",
        now_ms: 1_100
      )
    end
  end
end
