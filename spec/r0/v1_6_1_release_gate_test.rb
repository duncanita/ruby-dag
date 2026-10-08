# frozen_string_literal: true

require_relative "../test_helper"

class R0V161ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_version_and_release_notes_cover_waiting_revision_fix
    assert_operator Gem::Version.new(DAG::VERSION), :>=, Gem::Version.new("1.6.1")

    changelog = normalized("CHANGELOG.md")
    assert_includes changelog, "## 1.6.1 —"
    assert_includes changelog, "blocking effect links across definition revisions"

    roadmap = normalized("ROADMAP.md")
    assert_includes roadmap, "Waiting revision fix"
    assert_includes roadmap, "Release v1.6.1"
  end
end
