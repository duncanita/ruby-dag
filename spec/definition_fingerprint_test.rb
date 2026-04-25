# frozen_string_literal: true

require_relative "test_helper"

class DefinitionFingerprintTest < Minitest::Test
  include TestHelpers

  def test_same_definition_yields_same_digest
    definition = simple_definition
    a = DAG::Workflow::DefinitionFingerprint.for(definition)
    b = DAG::Workflow::DefinitionFingerprint.for(definition)
    assert_equal a, b
  end

  def test_equivalent_definitions_yield_same_digest
    a = DAG::Workflow::DefinitionFingerprint.for(simple_definition)
    b = DAG::Workflow::DefinitionFingerprint.for(simple_definition)
    assert_equal a, b
  end

  def test_shared_object_refs_in_input_do_not_change_digest
    shared = {"FOO" => "bar", "BAZ" => "qux"}
    shared_def = build_test_workflow(
      s1: {command: "echo a", env: shared},
      s2: {command: "echo b", env: shared, depends_on: [:s1]}
    )

    fresh_def = build_test_workflow(
      s1: {command: "echo a", env: {"FOO" => "bar", "BAZ" => "qux"}},
      s2: {command: "echo b", env: {"FOO" => "bar", "BAZ" => "qux"}, depends_on: [:s1]}
    )

    shared_digest = DAG::Workflow::DefinitionFingerprint.for(shared_def)
    fresh_digest = DAG::Workflow::DefinitionFingerprint.for(fresh_def)

    assert_equal shared_digest, fresh_digest,
      "fingerprint must not depend on whether subtrees share a Ruby object reference"
  end

  def test_different_graph_topology_changes_digest
    chain = build_test_workflow(s1: {}, s2: {depends_on: [:s1]})
    parallel = build_test_workflow(s1: {}, s2: {})

    refute_equal(
      DAG::Workflow::DefinitionFingerprint.for(chain),
      DAG::Workflow::DefinitionFingerprint.for(parallel)
    )
  end

  def test_different_step_config_changes_digest
    a = build_test_workflow(s1: {command: "echo a"})
    b = build_test_workflow(s1: {command: "echo b"})

    refute_equal(
      DAG::Workflow::DefinitionFingerprint.for(a),
      DAG::Workflow::DefinitionFingerprint.for(b)
    )
  end

  def test_root_input_change_changes_digest
    definition = simple_definition
    refute_equal(
      DAG::Workflow::DefinitionFingerprint.for(definition, root_input: {x: 1}),
      DAG::Workflow::DefinitionFingerprint.for(definition, root_input: {x: 2})
    )
  end

  def test_omitted_and_empty_root_input_yield_same_digest
    definition = simple_definition
    assert_equal(
      DAG::Workflow::DefinitionFingerprint.for(definition),
      DAG::Workflow::DefinitionFingerprint.for(definition, root_input: {})
    )
  end

  def test_root_input_string_vs_symbol_keys_differ
    definition = simple_definition
    refute_equal(
      DAG::Workflow::DefinitionFingerprint.for(definition, root_input: {payload: {"x" => 1}}),
      DAG::Workflow::DefinitionFingerprint.for(definition, root_input: {payload: {x: 1}})
    )
  end

  def test_canonical_encode_is_deterministic_under_hash_key_reordering
    encoder = DAG::Workflow::DefinitionFingerprint
    a = encoder.send(:canonical_encode, {b: 2, a: 1, c: 3})
    b = encoder.send(:canonical_encode, {a: 1, c: 3, b: 2})
    assert_equal a, b
  end

  def test_canonical_encode_is_alias_free
    encoder = DAG::Workflow::DefinitionFingerprint
    shared_leaf = {"FOO" => "bar"}
    shared_tree = {a: shared_leaf, b: shared_leaf}
    fresh_tree = {a: {"FOO" => "bar"}, b: {"FOO" => "bar"}}

    assert_equal(
      encoder.send(:canonical_encode, shared_tree),
      encoder.send(:canonical_encode, fresh_tree)
    )
  end

  def test_canonical_encode_distinguishes_strings_and_symbols
    encoder = DAG::Workflow::DefinitionFingerprint
    refute_equal(
      encoder.send(:canonical_encode, :foo),
      encoder.send(:canonical_encode, "foo")
    )
  end

  def test_canonical_encode_distinguishes_integer_and_string_forms
    encoder = DAG::Workflow::DefinitionFingerprint
    refute_equal(
      encoder.send(:canonical_encode, 1),
      encoder.send(:canonical_encode, "1")
    )
  end

  def test_canonical_encode_handles_floats_bools_and_nil
    encoder = DAG::Workflow::DefinitionFingerprint
    encoded = encoder.send(:canonical_encode, [1.5, true, false, nil])
    assert_equal "[1.5,true,false,nil]", encoded
  end

  def test_canonical_encode_rejects_unknown_types
    encoder = DAG::Workflow::DefinitionFingerprint
    error = assert_raises(DAG::SerializationError) do
      encoder.send(:canonical_encode, Object.new)
    end
    assert_match(/non-canonical fingerprint value/, error.message)
  end

  def test_sub_workflow_child_change_propagates_to_parent_fingerprint
    parent_a = sub_workflow_definition(child_resume_key: "child-v1")
    parent_b = sub_workflow_definition(child_resume_key: "child-v2")

    refute_equal(
      DAG::Workflow::DefinitionFingerprint.for(parent_a),
      DAG::Workflow::DefinitionFingerprint.for(parent_b)
    )
  end

  private

  def simple_definition
    build_test_workflow(
      s1: {command: "echo a"},
      s2: {command: "echo b", depends_on: [:s1]}
    )
  end

  def sub_workflow_definition(child_resume_key:)
    child = build_test_workflow(
      leaf: {
        type: :ruby,
        resume_key: child_resume_key,
        callable: ->(_) { DAG::Success.new(value: "ok") }
      }
    )

    parent_graph = DAG::Graph.new
    parent_graph.add_node(:nested)

    parent_registry = DAG::Workflow::Registry.new
    parent_registry.register(
      DAG::Workflow::Step.new(
        name: :nested,
        type: :sub_workflow,
        resume_key: "parent-v1",
        definition: child,
        output_key: :leaf
      )
    )

    DAG::Workflow::Definition.new(graph: parent_graph, registry: parent_registry)
  end
end
