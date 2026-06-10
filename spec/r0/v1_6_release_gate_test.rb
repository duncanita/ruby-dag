# frozen_string_literal: true

require_relative "../test_helper"

class R0V16ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_version_is_bumped_to_review_hardening_release
    assert_equal "1.6.0", DAG::VERSION
  end

  def test_changelog_contains_v1_6_release_notes
    changelog = normalized("CHANGELOG.md")

    assert_includes changelog, "## 1.6.0 — 2026-06-10"
    assert_includes changelog, "Project-review hardening pass"
    assert_includes changelog, "DAG::Ports::EffectLedger"
    assert_includes changelog, "DAG::Effects::DispatchAbortedError"
    assert_includes changelog, ":workflow_retrying"
  end

  def test_roadmap_marks_v1_6_release
    roadmap = normalized("ROADMAP.md")

    assert_includes roadmap, "V1.6 review hardening"
    assert_includes roadmap, "Release v1.6"
  end

  def test_effect_ledger_port_carries_the_canonical_completion_defaults
    port = File.read(File.join(ROOT, "lib/dag/ports/effect_ledger.rb"))

    assert_includes port, "module EffectLedger"
    assert_includes port, "def complete_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:)"
    assert_includes port, "def complete_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)"
    assert_includes port, "def thread_safe_for_dispatch?"
    assert_includes DAG::Ports::Storage.ancestors, DAG::Ports::EffectLedger
    refute File.read(File.join(ROOT, "lib/dag/ports/storage.rb")).include?("method_overridden?")
  end

  def test_dispatcher_exposes_per_workflow_tick_and_abort_report
    dispatcher = File.read(File.join(ROOT, "lib/dag/effects/dispatcher.rb"))

    assert_includes dispatcher, "def tick(limit:, only_workflow_id: nil)"
    assert_includes dispatcher, "DispatchAbortedError"
    assert_operator DAG::Effects::DispatchAbortedError, :<, DAG::Error
    assert DAG::Effects::DispatchAbortedError.instance_method(:report)
  end

  def test_event_types_include_workflow_retrying
    assert_includes DAG::Event::TYPES, :workflow_retrying
    assert_equal :retrying, DAG::TraceRecord::EVENT_STATUS.fetch(:workflow_retrying)
  end

  def test_result_from_h_round_trips_every_step_outcome
    success = DAG::Success[value: 1, context_patch: {"k" => "v"}]
    failure = DAG::Failure[error: {"code" => "x"}, retriable: true]
    waiting = DAG::Waiting[reason: :external, not_before_ms: 5]

    [success, failure, waiting].each do |outcome|
      assert_equal outcome, DAG::Result.from_h(outcome.to_h)
    end
  end

  def test_ci_enforces_the_coverage_gate
    workflow = File.read(File.join(ROOT, ".github/workflows/ci.yml"))

    assert_includes workflow, "COVERAGE"
    refute_path_exists File.join(ROOT, ".github/workflows/ruby.yml")
  end
end
