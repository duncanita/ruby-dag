# frozen_string_literal: true

require_relative "../test_helper"

class R0V14ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_version_is_bumped_to_contract_release
    assert_equal "1.4.0", DAG::VERSION
  end

  def test_changelog_contains_v1_4_release_notes
    changelog = normalized("CHANGELOG.md")

    assert_includes changelog, "## 1.4.0 — 2026-05-13"
    assert_includes changelog, "only_workflow_id"
    assert_includes changelog, "restrict `claim_ready_effects` to a single workflow"
    assert_includes changelog, "byte-identical"
  end

  def test_roadmap_marks_v1_4_release
    roadmap = normalized("ROADMAP.md")

    assert_includes roadmap, "V1.4 per-workflow effect claim"
    assert_includes roadmap, "Release v1.4"
  end

  def test_port_exposes_only_workflow_id_kwarg
    port = File.read(File.join(ROOT, "lib/dag/ports/storage.rb"))

    assert_includes port, "def claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:, only_workflow_id: nil)"
    assert_includes port, "only_workflow_id [String, nil]"
  end

  def test_memory_adapter_forwards_only_workflow_id_kwarg
    storage = File.read(File.join(ROOT, "lib/dag/adapters/memory/storage.rb"))
    storage_state = File.read(File.join(ROOT, "lib/dag/adapters/memory/storage_state.rb"))

    assert_includes storage, "def claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:, only_workflow_id: nil)"
    assert_includes storage_state, "def claim_ready_effects(state, limit:, owner_id:, lease_ms:, now_ms:, only_workflow_id: nil)"
  end

  def test_contract_suite_pins_only_workflow_id_semantics
    suite = File.read(File.join(ROOT, "lib/dag/testing/storage_contract/effects.rb"))

    assert_includes suite, "test_contract_claim_ready_effects_only_workflow_id_scopes_to_attempt_linked_workflow"
    assert_includes suite, "test_contract_claim_ready_effects_only_workflow_id_sees_shared_record_via_attempt_link"
    assert_includes suite, "test_contract_claim_ready_effects_default_only_workflow_id_is_global"
    assert_includes suite, "test_contract_claim_ready_effects_explicit_nil_only_workflow_id_is_global"
    assert_includes suite, "test_contract_claim_ready_effects_unknown_workflow_id_returns_empty"
    assert_includes suite, "test_contract_claim_ready_effects_only_workflow_id_validates_type"
  end

  def test_contract_documents_only_workflow_id_predicate
    contract = normalized("CONTRACT.md")

    assert_includes contract, "claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:, only_workflow_id: nil)"
    assert_includes contract, "V1.4 adds `only_workflow_id: nil`"
    assert_includes contract, "at least one attempt-effect link belonging to the given workflow"
  end
end
