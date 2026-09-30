# frozen_string_literal: true

module DAG::Testing::StorageContract
  module DispatchHistory
    def test_contract_dispatch_history_renewal_and_success
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      effect = contract_commit_waiting_effect(storage, workflow_id, :a)
      assert_equal 0, effect.dispatch_count
      assert_nil effect.claimed_at_ms
      assert_equal 0, effect.active_dispatch_ms

      claimed = storage.claim_ready_effects(limit: 1, owner_id: "a", lease_ms: 100, now_ms: 1_000).first
      assert_equal 1, claimed.dispatch_count
      assert_equal 1_000, claimed.claimed_at_ms
      assert_equal 0, claimed.active_dispatch_ms
      renewed = storage.renew_effect_lease(effect_id: effect.id, owner_id: "a", until_ms: 1_200, now_ms: 1_050)
      assert_equal 1, renewed.dispatch_count
      assert_equal 1_000, renewed.claimed_at_ms
      assert_equal 0, renewed.active_dispatch_ms

      completed = storage.complete_effect_succeeded(effect_id: effect.id, owner_id: "a",
        result: {ok: true}, external_ref: nil, now_ms: 1_150)[:record]
      assert_equal 1, completed.dispatch_count
      assert_nil completed.claimed_at_ms
      assert_equal 150, completed.active_dispatch_ms
    end

    def test_contract_dispatch_history_excludes_idle_gap_and_counts_reclaims
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      effect = contract_commit_waiting_effect(storage, workflow_id, :a)
      storage.claim_ready_effects(limit: 1, owner_id: "a", lease_ms: 100, now_ms: 1_000)

      reclaimed = storage.claim_ready_effects(limit: 1, owner_id: "b", lease_ms: 100, now_ms: 5_000).first
      assert_equal 2, reclaimed.dispatch_count
      assert_equal 100, reclaimed.active_dispatch_ms
      assert_equal 5_000, reclaimed.claimed_at_ms
      assert_empty storage.claim_ready_effects(limit: 1, owner_id: "racer", lease_ms: 100, now_ms: 5_000)
      failed = storage.complete_effect_failed(effect_id: effect.id, owner_id: "b",
        error: {code: "retry"}, retriable: true, not_before_ms: nil, now_ms: 5_050)[:record]
      assert_equal 150, failed.active_dispatch_ms
      assert_nil failed.claimed_at_ms

      retried = storage.claim_ready_effects(limit: 1, owner_id: "c", lease_ms: 100, now_ms: 10_000).first
      assert_equal 3, retried.dispatch_count
      assert_equal 150, retried.active_dispatch_ms
      terminal = storage.complete_effect_failed(effect_id: effect.id, owner_id: "c",
        error: {code: "terminal"}, retriable: false, not_before_ms: nil, now_ms: 10_020)[:record]
      assert_equal 170, terminal.active_dispatch_ms
      assert_equal 3, storage.list_effects_for_attempt(attempt_id: effect.attempt_id).first.dispatch_count
    end

    def test_contract_dispatch_history_exact_expiry_and_renewed_reclaim
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      first = contract_commit_waiting_effect(storage, workflow_id, :a, effect_key: "first")
      second = contract_commit_waiting_effect(storage, workflow_id, :b, effect_key: "second")
      storage.claim_ready_effects(limit: 2, owner_id: "a", lease_ms: 100, now_ms: 1_000)
      storage.renew_effect_lease(effect_id: second.id, owner_id: "a", until_ms: 1_200, now_ms: 1_050)
      assert_empty storage.claim_ready_effects(limit: 2, owner_id: "b", lease_ms: 100, now_ms: 1_100)
      completed = storage.complete_effect_succeeded(effect_id: first.id, owner_id: "a",
        result: {}, external_ref: nil, now_ms: 1_100)[:record]
      assert_equal 100, completed.active_dispatch_ms

      reclaimed = storage.claim_ready_effects(limit: 1, owner_id: "b", lease_ms: 100, now_ms: 1_300).first
      assert_equal second.id, reclaimed.id
      assert_equal 2, reclaimed.dispatch_count
      assert_equal 200, reclaimed.active_dispatch_ms
      terminal = storage.complete_effect_succeeded(effect_id: second.id, owner_id: "b",
        result: {}, external_ref: nil, now_ms: 1_350)[:record]
      assert_equal 250, terminal.active_dispatch_ms
    end
  end
end
