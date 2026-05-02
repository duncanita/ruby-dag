# frozen_string_literal: true

require_relative "../test_helper"

class R0KernelBoundaryDocsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def normalized(text)
    text.split.join(" ")
  end

  def test_contract_leads_with_kernel_boundary_and_non_goals
    contract = File.read(File.join(ROOT, "CONTRACT.md"))

    boundary_index = contract.index("## Kernel Boundary")
    step_protocol_index = contract.index("## Step Protocol")

    refute_nil boundary_index, "CONTRACT.md must start with an explicit kernel boundary section"
    refute_nil step_protocol_index, "CONTRACT.md must still document the step protocol"
    assert_operator boundary_index, :<, step_protocol_index

    normalized_contract = normalized(contract)

    [
      "`ruby-dag` owns only",
      "### Non-goals",
      "graph, definition, revision, and scheduling semantics",
      "`Runner` orchestration over injected ports",
      "step result transport",
      "abstract effect intent reservation and dispatch coordination",
      "mutation/revision APIs",
      "retry/recovery rules",
      "event log and diagnostic contract",
      "Consumers own",
      "concrete storage adapters beyond memory examples",
      "concrete effect handlers",
      "LLM/model/tool semantics",
      "application-level budgets, approvals, policy, and UI streaming",
      "consumer-owned runtime/domain objects, orchestration facades, per-run application context/results, and channel/stream behavior"
    ].each do |required_text|
      assert_includes normalized_contract, required_text
    end

    refute_includes normalized_contract, "Delphi-specific"
    refute_includes normalized_contract, "Delphi"
    refute_includes normalized_contract, "Delphic"
    refute_includes normalized_contract, "`Plan`"
    refute_includes normalized_contract, "`Agent`"
    refute_includes normalized_contract, "`RunContext`"
    refute_includes normalized_contract, "`RunResult`"
  end

  def test_readme_explains_production_ports_and_consumer_adapters
    readme = File.read(File.join(ROOT, "README.md"))
    normalized_readme = normalized(readme)

    assert_includes normalized_readme, "Production callers inject the public ports"
    %w[storage event_bus registry clock id_generator fingerprint serializer].each do |port_name|
      assert_includes normalized_readme, "`#{port_name}:`"
    end
    assert_includes normalized_readme, "durable production adapters can live in consumer repositories"
    assert_includes normalized_readme, "Delphi can be treated as a reference consumer"
    assert_includes normalized_readme, "not part of the kernel contract"
    assert_includes normalized_readme, "Non-normative reference-consumer note"
    assert_includes normalized_readme, "consumer-owned runtime objects"
    assert_includes normalized_readme, "application context, result wrappers, and channel behavior"
    assert_includes normalized_readme, "not `DAG::RunResult`"
    assert_includes normalized_readme, "do not constrain other consumers"
    refute_includes normalized_readme, "`Plan`"
    refute_includes normalized_readme, "`Agent`"
    refute_includes normalized_readme, "`RunContext`"
  end
end
