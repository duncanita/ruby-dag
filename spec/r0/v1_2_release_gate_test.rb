# frozen_string_literal: true

require_relative "../test_helper"

class R0V12ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def normalized(path)
    File.read(File.join(ROOT, path)).split.join(" ")
  end

  def test_version_is_bumped_to_contract_release
    assert_equal "1.2.0", DAG::VERSION
  end

  def test_changelog_contains_v1_2_release_notes
    changelog = normalized("CHANGELOG.md")

    assert_includes changelog, "## 1.2.0 — 2026-05-07"
    assert_includes changelog, "cooperative lease renewal"
    assert_includes changelog, "renew_effect_lease"
    assert_includes changelog, "7134e4d6"
    assert_includes changelog, "b540702c"
  end

  def test_roadmap_marks_v1_2_release_done
    roadmap = normalized("ROADMAP.md")

    assert_includes roadmap, "V1.2 cooperative lease renewal"
    assert_includes roadmap, "Release v1.2"
  end

  def test_storage_port_documents_renew_effect_lease
    port = File.read(File.join(ROOT, "lib/dag/ports/storage.rb"))

    assert_includes port, "def renew_effect_lease(effect_id:, owner_id:, until_ms:, now_ms:)"
    assert_includes port.downcase, "cooperatively extend the lease"
  end

  def test_contract_documents_renew_effect_lease
    contract = normalized("CONTRACT.md")

    assert_includes contract, "renew_effect_lease(effect_id:, owner_id:, until_ms:, now_ms:)"
    assert_includes contract, "cooperatively extends the lease"
  end
end
