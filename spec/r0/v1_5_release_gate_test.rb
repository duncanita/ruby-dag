# frozen_string_literal: true

require_relative "../test_helper"

class R0V15ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_version_is_bumped_to_mutation_testing_release
    assert_equal "1.5.0", DAG::VERSION
  end

  def test_changelog_contains_v1_5_release_notes
    changelog = normalized("CHANGELOG.md")

    assert_includes changelog, "## 1.5.0 — 2026-05-18"
    assert_includes changelog, "mutation-testing release"
    assert_includes changelog, "mutant-minitest"
    assert_includes changelog, "rake mutant:run"
    assert_includes changelog, "100% mutation coverage"
  end

  def test_roadmap_marks_v1_5_release
    roadmap = normalized("ROADMAP.md")

    assert_includes roadmap, "V1.5 mutation testing gate"
    assert_includes roadmap, "Release v1.5"
  end

  def test_mutant_configuration_pins_focused_subjects
    mutant_config = normalized(".mutant.yml")

    assert_includes mutant_config, "integration: name: minitest"
    assert_includes mutant_config, "fail_fast: true"
    assert_includes mutant_config, "DAG::Graph*"
    assert_includes mutant_config, "DAG::Effects::Await*"
  end

  def test_rakefile_exposes_mutant_tasks
    rakefile = File.read(File.join(ROOT, "Rakefile"))

    assert_includes rakefile, "task :test"
    assert_includes rakefile, "bundle exec mutant test"
    assert_includes rakefile, "task :run"
    assert_includes rakefile, "bundle exec mutant run --fail-fast"
    assert_includes rakefile, "task :changed"
    assert_includes rakefile, "MUTANT_SINCE"
  end

  def test_mutant_bridge_loads_spec_suite
    bridge = File.read(File.join(ROOT, "test/all_test.rb"))
    helper = File.read(File.join(ROOT, "spec/test_helper.rb"))

    assert_includes bridge, "../spec/**/*_test.rb"
    assert_includes helper, 'require "mutant/minitest/coverage"'
  end
end
