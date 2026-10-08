# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/storage_contract"

class EffectDispatchHistoryTest < Minitest::Test
  include DAG::Testing::StorageContract::Helpers

  def test_public_record_excludes_long_idle_time_after_expiry
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = contract_create_workflow(storage)
    effect = contract_commit_waiting_effect(storage, workflow_id, :a)

    storage.claim_ready_effects(limit: 1, owner_id: "first", lease_ms: 100, now_ms: 1_000)
    reclaimed = storage.claim_ready_effects(limit: 1, owner_id: "second", lease_ms: 100, now_ms: 10_000).first
    assert_equal 2, reclaimed.dispatch_count
    assert_equal 100, reclaimed.active_dispatch_ms
    assert_equal 10_000, reclaimed.claimed_at_ms

    completion = storage.complete_effect_succeeded(effect_id: effect.id, owner_id: "second",
      result: {ok: true}, external_ref: "done", now_ms: 10_040)
    record = storage.list_effects_for_attempt(attempt_id: effect.attempt_id).first
    assert_equal completion[:record], record
    assert_equal 2, record.dispatch_count
    assert_nil record.claimed_at_ms
    assert_equal 140, record.active_dispatch_ms
    assert_equal 140, record.to_snapshot[:active_dispatch_ms]
    assert record.frozen?
  end

  def test_pre_history_persisted_record_migrates_with_zero_defaults
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = contract_create_workflow(storage)
    effect = contract_commit_waiting_effect(storage, workflow_id, :a)
    legacy_state = DAG.deep_dup(storage.instance_variable_get(:@state))
    legacy_state[:effects][effect.id] = JSON.parse(JSON.generate(
      effect.to_h.except(:dispatch_count, :claimed_at_ms, :active_dispatch_ms)
    ))
    legacy_state.delete(:effect_history_migrated)

    migrated = DAG::Adapters::Memory::Storage.new(initial_state: legacy_state)
    record = migrated.list_effects_for_attempt(attempt_id: effect.attempt_id).first
    assert_equal 0, record.dispatch_count
    assert_nil record.claimed_at_ms
    assert_equal 0, record.active_dispatch_ms
    assert_equal 1, migrated.claim_ready_effects(limit: 1, owner_id: "worker", lease_ms: 100,
      now_ms: 1_000).first.dispatch_count
  end

  def test_pre_history_dispatching_record_starts_a_new_accounting_baseline
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = contract_create_workflow(storage)
    effect = contract_commit_waiting_effect(storage, workflow_id, :a)
    claimed = storage.claim_ready_effects(limit: 1, owner_id: "old", lease_ms: 100, now_ms: 1_000).first
    legacy_state = DAG.deep_dup(storage.instance_variable_get(:@state))
    legacy_state[:effects][effect.id] = JSON.parse(JSON.generate(
      claimed.to_h.except(:dispatch_count, :claimed_at_ms, :active_dispatch_ms)
    ))
    legacy_state.delete(:effect_history_migrated)
    migrated = DAG::Adapters::Memory::Storage.new(initial_state: legacy_state)

    reclaimed = migrated.claim_ready_effects(limit: 1, owner_id: "new", lease_ms: 100, now_ms: 5_000).first
    assert_equal 1, reclaimed.dispatch_count
    assert_equal 0, reclaimed.active_dispatch_ms
    assert_equal 5_000, reclaimed.claimed_at_ms
    terminal = migrated.complete_effect_succeeded(effect_id: effect.id, owner_id: "new",
      result: {}, external_ref: nil, now_ms: 5_050)[:record]
    assert_equal 50, terminal.active_dispatch_ms
  end
end
