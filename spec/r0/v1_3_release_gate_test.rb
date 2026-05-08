# frozen_string_literal: true

require_relative "../test_helper"

class R0V13ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_version_is_bumped_to_contract_release
    assert_equal "1.3.0", DAG::VERSION
  end

  def test_changelog_contains_v1_3_release_notes
    changelog = normalized("CHANGELOG.md")

    assert_includes changelog, "## 1.3.0 — 2026-05-08"
    assert_includes changelog, "bounded intra-tick parallel dispatch"
    assert_includes changelog, "DAG::Effects::Dispatcher.new(parallelism: 1)"
    assert_includes changelog, "thread_safe_for_dispatch?"
  end

  def test_roadmap_marks_v1_3_release_done
    roadmap = normalized("ROADMAP.md")

    assert_includes roadmap, "V1.3 dispatcher parallelism"
    assert_includes roadmap, "Release v1.3"
  end

  def test_dispatcher_exposes_parallelism_kwarg
    dispatcher = File.read(File.join(ROOT, "lib/dag/effects/dispatcher.rb"))

    assert_includes dispatcher, "parallelism: 1"
    assert_includes dispatcher, "def parallel_map(items)"
    assert_includes dispatcher, "def validate_parallelism_storage!"
    assert_includes dispatcher, "thread_safe_for_dispatch?"
  end

  def test_contract_documents_dispatcher_concurrency
    contract = normalized("CONTRACT.md")

    assert_includes contract, "Dispatcher Concurrency Contract"
    assert_includes contract, "thread_safe_for_dispatch?"
    assert_includes contract, "parallelism > 1"
  end
end
