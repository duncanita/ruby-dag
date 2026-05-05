# frozen_string_literal: true

require_relative "../test_helper"

class R0V11ReleaseGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def normalized(path)
    File.read(File.join(ROOT, path)).split.join(" ")
  end

  def normalized_section(path, start_marker, end_marker)
    text = File.read(File.join(ROOT, path))
    text.fetch_after(start_marker).fetch_before(end_marker).split.join(" ")
  end

  def test_version_is_bumped_to_contract_release
    assert_equal "1.1.0", DAG::VERSION
  end

  def test_changelog_contains_v1_1_contract_release_notes
    changelog = normalized("CHANGELOG.md")

    assert_includes changelog, "## 1.1.0 — 2026-05-03"
    assert_includes changelog, "V1.1 is a contract hardening release"
    assert_includes changelog, "contains no Delphi-specific implementation"
    assert_includes changelog, "RD-01 through RD-08 are complete"
    assert_includes changelog, "DAG::RuntimeSnapshot"
    assert_includes changelog, "DAG::TraceRecord"
    assert_includes changelog, "DAG::NodeDiagnostic"
    assert_includes changelog, "DAG::Testing::StorageContract::All"
    assert_includes changelog, "Bounded recovery controls"
  end

  def test_contract_lists_stable_consumer_apis_and_port_extension_checklist
    contract = normalized("CONTRACT.md")

    assert_includes contract, "## V1.1 Consumer Compatibility Matrix"
    assert_includes contract, "Stable consumer APIs"
    assert_includes contract, "DAG::Runner#call"
    assert_includes contract, "DAG::Runner#resume"
    assert_includes contract, "DAG::Runner#retry_workflow"
    assert_includes contract, "DAG::RuntimeSnapshot"
    assert_includes contract, "DAG::TraceRecord"
    assert_includes contract, "DAG::NodeDiagnostic"
    assert_includes contract, "DAG::Testing::StorageContract::All"
    assert_includes contract, "Required for durable adapters"
    assert_includes contract, "Recommended for durable adapters"
    assert_includes contract, "Optional for simple consumers"
    assert_includes contract, "Durable adapter adoption checklist"
  end

  def test_readme_and_roadmap_reflect_v1_1_release_state
    readme = normalized("README.md")
    roadmap = normalized("ROADMAP.md")

    assert_includes readme, "V1.1 contract release"
    assert_includes readme, "Compatibility matrix"
    assert_includes readme, "Delphi's SQLite adapter"
    assert_includes roadmap, "V1.1 kernel hardening"
    assert_includes roadmap, "Done (#158-#164 via #166, #167, #168, #169, #170, #171, #172)"
    assert_includes roadmap, "Release v1.1"
    assert_includes roadmap, "Done"
  end

  def test_readme_effect_examples_use_valid_colon_free_identity_parts
    readme = File.read(File.join(ROOT, "README.md"))

    refute_includes readme, '"wf:#{input.metadata.fetch(:workflow_id)}"'
    refute_includes readme, '"rev:#{input.metadata.fetch(:revision)}"'
    refute_includes readme, '"node:#{input.node_id}"'
    assert_includes readme, "wf"
    assert_includes readme, "rev"
    assert_includes readme, "node"
    assert_includes readme, '.join("/")'
    assert_includes readme, "must not include `:`"
  end

  def test_execution_plan_effect_examples_use_valid_colon_free_identity_parts
    plan = File.read(File.join(ROOT, "Delphi Ruby DAG Execution Plan.md"))

    refute_includes plan, "delphi:v1:wf:<workflow_id>"
    refute_includes plan, '"wf:#{input.metadata.fetch(:workflow_id)}"'
    refute_includes plan, '"rev:#{input.metadata.fetch(:revision)}"'
    refute_includes plan, '"node:#{input.node_id}"'
    refute_includes plan, '"prompt:#{prompt_fingerprint}"'
    assert_includes plan, "delphi/v1/wf/<workflow_id>/rev/<revision>/node/<node_id>/planner/<prompt_fingerprint>"
    assert_includes plan, "validate_ref_part!"
    assert_includes plan, "ref_for(type, key)"
    assert_includes plan, "prive di `:`"
  end

  def test_execution_plan_marks_original_implementation_sequence_as_historical
    plan = File.read(File.join(ROOT, "Delphi Ruby DAG Execution Plan.md"))

    refute_includes plan, "## 10. Ordine operativo per oggi"
    refute_includes plan, "Eseguire in questo ordine."
    assert_includes plan, "## 10. Sequenza storica di implementazione"
    assert_includes plan, "Questa sezione conserva l'ordine originale"
  end

  def test_execution_plan_uses_generic_provider_language_in_public_gates
    plan = File.read(File.join(ROOT, "Delphi Ruby DAG Execution Plan.md"))

    assert_includes plan, "OpenAI"
    assert_includes plan, "Adapter concreti OpenAI/GitHub/email dentro ruby-dag."
  end

  def test_public_contract_docs_are_self_contained
    contract = File.read(File.join(ROOT, "CONTRACT.md"))
    storage_port = File.read(File.join(ROOT, "lib/dag/ports/storage.rb"))

    refute_includes contract, "CLAUDE.md"
    refute_includes storage_port, "CLAUDE.md"
    assert_includes contract, "workflow state and its corresponding terminal event must be durable together"
    assert_includes storage_port, "Port extension: with a CAS guard"
  end
end
