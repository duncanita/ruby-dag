# frozen_string_literal: true

require_relative "../test_helper"

class DefinitionTest < Minitest::Test
  def test_revision_starts_at_one
    definition = DAG::Workflow::Definition.new
    assert_equal 1, definition.revision
  end

  def test_chain_returns_new_frozen_instances
    a = DAG::Workflow::Definition.new
    b = a.add_node(:n, type: :passthrough)
    refute_same a, b
    assert b.frozen?
    assert_equal 0, a.nodes.size
    assert_equal 1, b.nodes.size
  end

  def test_step_type_for_returns_type_and_config
    definition = DAG::Workflow::Definition.new.add_node(:n, type: :passthrough, config: {weight: 4})
    entry = definition.step_type_for(:n)
    assert_equal :passthrough, entry[:type]
    assert_equal({weight: 4}, entry[:config])
  end

  def test_step_type_for_unknown_raises
    assert_raises(DAG::UnknownNodeError) { DAG::Workflow::Definition.new.step_type_for(:nope) }
  end

  def test_to_h_is_canonical
    a = DAG::Workflow::Definition.new
      .add_node(:b, type: :passthrough)
      .add_node(:a, type: :passthrough)
      .add_edge(:a, :b)
    b = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_edge(:a, :b)
    assert_equal a.to_h, b.to_h
  end

  def test_fingerprint_uses_port
    definition = DAG::Workflow::Definition.new.add_node(:a, type: :passthrough)
    fingerprint = DAG::Adapters::Stdlib::Fingerprint.new
    digest = definition.fingerprint(via: fingerprint)
    assert_match(/\A[0-9a-f]{64}\z/, digest)
  end

  def test_cycle_propagates_from_graph
    base = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_edge(:a, :b)
    assert_raises(DAG::CycleError) { base.add_edge(:b, :a) }
  end

  def test_equality_is_structural
    a = DAG::Workflow::Definition.new.add_node(:n, type: :passthrough)
    b = DAG::Workflow::Definition.new.add_node(:n, type: :passthrough)
    assert_equal a, b
    assert_equal a.hash, b.hash
    refute_equal a, DAG::Workflow::Definition.new.add_node(:other, type: :passthrough)
    refute_equal a, "not a definition"
  end

  def test_hash_is_stable_when_to_h_result_is_mutated
    definition = DAG::Workflow::Definition.new.add_node(:n, type: :passthrough)
    hash = definition.hash

    definition.to_h[:nodes] << {id: :other, type: :passthrough, config: {}}

    assert_equal hash, definition.hash
  end

  def test_builder_builds_equivalent_frozen_definition
    built = DAG::Workflow::Definition::Builder.build do |b|
      b.add_node(:a, type: :passthrough, config: {x: [1]})
      b.add_node(:b, type: :noop)
      b.add_edge(:a, :b, label: "next")
    end
    chained = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough, config: {x: [1]})
      .add_node(:b, type: :noop)
      .add_edge(:a, :b, label: "next")

    assert_equal chained, built
    assert built.frozen?
    assert_raises(FrozenError) { built.step_type_for(:a)[:config][:x] << 2 }
  end

  def test_builder_rejects_invalid_revision
    assert_raises(ArgumentError) do
      DAG::Workflow::Definition::Builder.build(revision: 0) { |_| }
    end
  end
end
