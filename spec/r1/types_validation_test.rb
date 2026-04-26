# frozen_string_literal: true

require_relative "../test_helper"

class TypesValidationTest < Minitest::Test
  def test_replacement_graph_rejects_empty_entry_or_exit
    g = DAG::Graph.new.add_node(:a).freeze
    assert_raises(ArgumentError) { DAG::ReplacementGraph[graph: g, entry_node_ids: [], exit_node_ids: [:a]] }
    assert_raises(ArgumentError) { DAG::ReplacementGraph[graph: g, entry_node_ids: [:a], exit_node_ids: []] }
  end

  def test_proposed_mutation_kind_validation
    assert_raises(ArgumentError) do
      DAG::ProposedMutation[kind: :unknown, target_node_id: :a]
    end
  end

  def test_proposed_mutation_replace_requires_replacement_graph
    assert_raises(ArgumentError) do
      DAG::ProposedMutation[kind: :replace_subtree, target_node_id: :a]
    end
  end

  def test_proposed_mutation_invalidate_rejects_replacement_graph
    g = DAG::ReplacementGraph[
      graph: DAG::Graph.new.tap { |gg| gg.add_node(:n) }.freeze,
      entry_node_ids: [:n],
      exit_node_ids: [:n]
    ]
    assert_raises(ArgumentError) do
      DAG::ProposedMutation[kind: :invalidate, target_node_id: :a, replacement_graph: g]
    end
  end

  def test_runtime_profile_rejects_invalid_durability
    assert_raises(ArgumentError) do
      DAG::RuntimeProfile[durability: :unknown, max_attempts_per_node: 1, max_workflow_retries: 0, event_bus_kind: :null]
    end
  end

  def test_runtime_profile_rejects_non_positive_attempts
    assert_raises(ArgumentError) do
      DAG::RuntimeProfile[durability: :ephemeral, max_attempts_per_node: 0, max_workflow_retries: 0, event_bus_kind: :null]
    end
  end

  def test_runtime_profile_rejects_negative_workflow_retries
    assert_raises(ArgumentError) do
      DAG::RuntimeProfile[durability: :ephemeral, max_attempts_per_node: 1, max_workflow_retries: -1, event_bus_kind: :null]
    end
  end

  def test_waiting_rejects_non_symbol_reason
    assert_raises(ArgumentError) { DAG::Waiting[reason: "external"] }
  end

  def test_waiting_rejects_non_integer_not_before_ms
    assert_raises(ArgumentError) { DAG::Waiting[reason: :ext, not_before_ms: 1.5] }
  end

  def test_waiting_at_uses_time
    waiting = DAG::Waiting.at(reason: :ext, time: Time.utc(2026, 1, 1))
    assert_equal :ext, waiting.reason
    assert_kind_of Integer, waiting.not_before_ms
  end

  def test_event_rejects_unknown_type
    assert_raises(ArgumentError) do
      DAG::Event[type: :nope, workflow_id: "x", revision: 1, at_ms: 0]
    end
  end

  def test_success_factory_rejects_non_mutation_in_proposed_mutations
    assert_raises(ArgumentError) do
      DAG::Success[value: 1, proposed_mutations: ["not a mutation"]]
    end
  end

  def test_json_safe_rejects_non_string_symbol_keys
    assert_raises(ArgumentError) { DAG.json_safe!({1 => :v}) }
  end

  def test_json_safe_accepts_known_value_classes
    assert_equal({a: 1}, DAG.json_safe!({a: 1}))
  end

  def test_step_base_default_call_raises
    klass = Class.new(DAG::Step::Base)
    assert_raises(NotImplementedError) { klass.new.call(:input) }
  end

  def test_noop_step_returns_nil_success
    result = DAG::BuiltinSteps::Noop.new.call(:anything)
    assert_kind_of DAG::Success, result
    assert_nil result.value
    assert_equal({}, result.context_patch)
  end

  def test_definition_with_revision_bumps_revision
    base = DAG::Workflow::Definition.new.add_node(:a, type: :passthrough)
    bumped = base.with_revision(2)
    assert_equal 1, base.revision
    assert_equal 2, bumped.revision
  end

  def test_definition_rejects_non_positive_revision
    assert_raises(ArgumentError) { DAG::Workflow::Definition.new(revision: 0) }
    assert_raises(ArgumentError) { DAG::Workflow::Definition.new(revision: "1") }
  end

  def test_definition_rejects_non_symbol_type
    assert_raises(ArgumentError) do
      DAG::Workflow::Definition.new.add_node(:a, type: "passthrough")
    end
  end

  def test_definition_freezes_unfrozen_graph
    unfrozen = DAG::Graph.new
    refute unfrozen.frozen?
    definition = DAG::Workflow::Definition.new(graph: unfrozen)
    assert definition.graph.frozen?
  end

  def test_step_protocol_valid_result_accepts_step_outcomes
    assert DAG::StepProtocol.valid_result?(DAG::Success[value: 1])
    assert DAG::StepProtocol.valid_result?(DAG::Waiting[reason: :ext])
    assert DAG::StepProtocol.valid_result?(DAG::Failure[error: {code: :x, message: "y"}])
  end

  def test_step_protocol_valid_result_rejects_other_values
    refute DAG::StepProtocol.valid_result?(:symbol)
    refute DAG::StepProtocol.valid_result?("string")
    refute DAG::StepProtocol.valid_result?({k: :v})
    refute DAG::StepProtocol.valid_result?(nil)
  end

  def test_step_type_registry_rejects_non_symbol_name
    reg = DAG::StepTypeRegistry.new
    assert_raises(ArgumentError) do
      reg.register(name: "passthrough", klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    end
  end

  def test_immutability_handles_circular_hash
    h = {}
    h[:self] = h
    DAG.deep_freeze(h)
    assert h.frozen?
  end

  def test_immutability_deep_dup_handles_circular_array
    a = []
    a << a
    duped = DAG.deep_dup(a)
    refute_same a, duped
  end
end
