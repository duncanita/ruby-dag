# frozen_string_literal: true

require_relative "../test_helper"

class R0V17ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_version_and_release_notes_cover_workflow_run_claims
    assert_operator Gem::Version.new(DAG::VERSION), :>=, Gem::Version.new("1.7.0")

    changelog = normalized("CHANGELOG.md")
    assert_includes changelog, "## 1.7.0 —"
    assert_includes changelog, "monotonic fencing tokens"

    roadmap = normalized("ROADMAP.md")
    assert_includes roadmap, "Workflow run claims"
    assert_includes roadmap, "Release v1.7.0"
  end
end
