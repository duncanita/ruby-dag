# frozen_string_literal: true

require_relative "../test_helper"

class R0V18ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_version_and_release_notes_cover_remaining_primitives
    assert_operator Gem::Version.new(DAG::VERSION), :>=, Gem::Version.new("1.8.0")

    changelog = normalized("CHANGELOG.md")
    assert_includes changelog, "## 1.8.0 —"
    assert_includes changelog, "cooperative effect-handler opt-in"
    assert_includes changelog, "PlanResult#code"
    assert_includes changelog, "Atomic workflow fork"
    assert_includes changelog, "active dispatch time"
    assert_includes changelog, "indexed storage queries"

    assert_includes normalized("ROADMAP.md"), "Release v1.8.0"
  end
end
