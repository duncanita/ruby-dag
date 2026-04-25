# frozen_string_literal: true

require_relative "test_helper"

class ConditionTest < Minitest::Test
  Condition = DAG::Workflow::Condition

  # --- normalize ---

  def test_normalize_nil_returns_nil
    assert_nil Condition.normalize(nil)
  end

  def test_normalize_callable_returns_callable
    callable = ->(input) { input[:check] }
    assert_same callable, Condition.normalize(callable)
  end

  def test_normalize_leaf_with_status
    result = Condition.normalize({from: :a, status: :success})
    assert_equal({from: :a, status: :success}, result)
  end

  def test_normalize_leaf_with_value_equals
    result = Condition.normalize({from: :a, value: {equals: "prod"}})
    assert_equal({from: :a, value: {equals: "prod"}}, result)
  end

  def test_normalize_leaf_with_value_in
    result = Condition.normalize({from: :a, value: {in: ["a", "b"]}})
    assert_equal({from: :a, value: {in: ["a", "b"]}}, result)
  end

  def test_normalize_leaf_with_value_present
    result = Condition.normalize({from: :a, value: {present: true}})
    assert_equal({from: :a, value: {present: true}}, result)
  end

  def test_normalize_leaf_with_value_nil
    result = Condition.normalize({from: :a, value: {nil: true}})
    assert_equal({from: :a, value: {nil: true}}, result)
  end

  def test_normalize_leaf_with_value_matches
    result = Condition.normalize({from: :a, value: {matches: "^prod"}})
    assert_equal :a, result[:from]
    assert_instance_of Regexp, result[:value][:matches]
    assert_equal "^prod", result[:value][:matches].source
  end

  def test_normalize_leaf_with_value_matches_preserves_verbose
    original = $VERBOSE
    $VERBOSE = true

    Condition.normalize({from: :a, value: {matches: "^prod"}})

    assert_equal true, $VERBOSE
  ensure
    $VERBOSE = original
  end

  def test_normalize_leaf_with_status_and_value
    result = Condition.normalize({from: :a, status: :success, value: {equals: "ok"}})
    assert_equal({from: :a, status: :success, value: {equals: "ok"}}, result)
  end

  def test_normalize_all
    result = Condition.normalize({all: [
      {from: :a, status: :success},
      {from: :b, value: {equals: 1}}
    ]})
    assert_equal :a, result[:all][0][:from]
    assert_equal :b, result[:all][1][:from]
  end

  def test_normalize_any
    result = Condition.normalize({any: [
      {from: :a, status: :success},
      {from: :b, status: :skipped}
    ]})
    assert_equal 2, result[:any].size
  end

  def test_normalize_not
    result = Condition.normalize({not: {from: :a, status: :skipped}})
    assert_equal :a, result[:not][:from]
    assert_equal :skipped, result[:not][:status]
  end

  def test_normalize_nested_all_any_not
    result = Condition.normalize({
      all: [
        {any: [{from: :a, status: :success}, {from: :b, status: :success}]},
        {not: {from: :c, status: :skipped}}
      ]
    })
    assert result[:all][0].key?(:any)
    assert result[:all][1].key?(:not)
  end

  def test_normalize_string_keys
    result = Condition.normalize({"from" => "a", "status" => "success"})
    assert_equal :a, result[:from]
    assert_equal :success, result[:status]
  end

  # --- normalize error cases ---

  def test_normalize_rejects_non_hash
    error = assert_raises(DAG::ValidationError) { Condition.normalize("bad") }
    assert_match(/must be a mapping/, error.message)
  end

  def test_normalize_rejects_missing_from
    error = assert_raises(DAG::ValidationError) { Condition.normalize({status: :success}) }
    assert_match(/must include :from/, error.message)
  end

  def test_normalize_rejects_from_only
    error = assert_raises(DAG::ValidationError) { Condition.normalize({from: :a}) }
    assert_match(/must include :status and\/or :value/, error.message)
  end

  def test_normalize_rejects_unknown_keys
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, status: :success, extra: true})
    end
    assert_match(/unsupported keys/, error.message)
  end

  def test_normalize_rejects_invalid_status
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, status: :running})
    end
    assert_match(/success, skipped/, error.message)
  end

  def test_normalize_rejects_non_hash_value
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: "bad"})
    end
    assert_match(/must be a mapping/, error.message)
  end

  def test_normalize_rejects_unknown_value_predicate
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {greater_than: 5}})
    end
    assert_match(/equals, in, present, nil, matches/, error.message)
  end

  def test_normalize_rejects_empty_value
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {}})
    end
    assert_match(/exactly one predicate/, error.message)
  end

  def test_normalize_rejects_multiple_value_predicates
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {equals: 1, present: true}})
    end
    assert_match(/exactly one predicate/, error.message)
  end

  def test_normalize_rejects_empty_all
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({all: []})
    end
    assert_match(/non-empty array/, error.message)
  end

  def test_normalize_rejects_non_array_any
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({any: "bad"})
    end
    assert_match(/non-empty array/, error.message)
  end

  def test_normalize_rejects_multiple_logical_keys
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({all: [{from: :a, status: :success}], not: {from: :b, status: :skipped}})
    end
    assert_match(/exactly one logical operator/, error.message)
  end

  def test_normalize_rejects_nil_nested_in_not
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({not: nil})
    end
    assert_match(/condition mapping, got nil/, error.message)
  end

  def test_normalize_rejects_nil_nested_in_all
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({all: [nil]})
    end
    assert_match(/condition mapping, got nil/, error.message)
  end

  def test_normalize_rejects_nil_nested_in_any
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({any: [{from: :a, status: :success}, nil]})
    end
    assert_match(/condition mapping, got nil/, error.message)
  end

  def test_normalize_rejects_callable_nested_in_not
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({not: ->(x) { true }})
    end
    assert_match(/not a callable/, error.message)
  end

  def test_normalize_rejects_callable_nested_in_all
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({all: [->(x) { true }]})
    end
    assert_match(/not a callable/, error.message)
  end

  def test_normalize_rejects_non_yaml_safe_equals
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {equals: /foo/}})
    end
    assert_match(/YAML-safe/, error.message)
    assert_match(/Regexp/, error.message)
  end

  def test_normalize_rejects_non_yaml_safe_in_element
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {in: ["ok", /bad/]}})
    end
    assert_match(/YAML-safe/, error.message)
    assert_match(/in\[1\]/, error.message)
  end

  def test_normalize_accepts_yaml_safe_equals_types
    # String, Symbol, Integer, Float, true, false all pass
    [42, 3.14, "prod", :staging, true, false].each do |val|
      result = Condition.normalize({from: :a, value: {equals: val}})
      assert_equal val, result[:value][:equals]
    end
    # nil separately to avoid assert_equal deprecation
    result = Condition.normalize({from: :a, value: {equals: nil}})
    assert_nil result[:value][:equals]
  end

  def test_normalize_rejects_value_in_with_empty_array
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {in: []}})
    end
    assert_match(/non-empty array/, error.message)
  end

  def test_normalize_rejects_present_non_true
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {present: false}})
    end
    assert_match(/present must be true/, error.message)
  end

  def test_normalize_rejects_nil_non_true
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {nil: false}})
    end
    assert_match(/nil must be true/, error.message)
  end

  def test_normalize_rejects_matches_empty_string
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {matches: ""}})
    end
    assert_match(/non-empty string/, error.message)
  end

  def test_normalize_rejects_matches_non_string
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {matches: 42}})
    end
    assert_match(/non-empty string/, error.message)
  end

  def test_normalize_rejects_invalid_regex
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: :a, value: {matches: "("}})
    end
    assert_match(/valid regular expression/, error.message)
  end

  def test_normalize_rejects_non_symbolizable_from
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({from: [], status: :success})
    end
    assert_match(/symbolizable/, error.message)
  end

  def test_normalize_rejects_logical_key_with_extra_keys
    error = assert_raises(DAG::ValidationError) do
      Condition.normalize({all: [{from: :a, status: :success}], extra: true})
    end
    assert_match(/exactly one logical operator/, error.message)
  end

  # --- evaluate ---

  def test_evaluate_nil_returns_true
    assert Condition.evaluate(nil, {})
  end

  def test_evaluate_status_success_match
    cond = {from: :a, status: :success}
    ctx = {a: {value: "ok", status: :success}}
    assert Condition.evaluate(cond, ctx)
  end

  def test_evaluate_status_success_mismatch
    cond = {from: :a, status: :success}
    ctx = {a: {value: nil, status: :skipped}}
    refute Condition.evaluate(cond, ctx)
  end

  def test_evaluate_callable_returning_true
    ctx = {a: {value: "ok", status: :success}}
    assert Condition.evaluate(->(input) { true }, ctx)
  end

  def test_evaluate_callable_returning_false
    ctx = {a: {value: "ok", status: :success}}
    refute Condition.evaluate(->(input) { false }, ctx)
  end

  def test_evaluate_callable_receives_value_only_hash
    ctx = {a: {value: "prod", status: :success}, b: {value: "ok", status: :success}}
    result = Condition.evaluate(->(input) { input == {a: "prod", b: "ok"} }, ctx)
    assert result
  end

  def test_evaluate_value_equals
    cond = {from: :a, value: {equals: "prod"}}
    assert Condition.evaluate(cond, {a: {value: "prod", status: :success}})
    refute Condition.evaluate(cond, {a: {value: "staging", status: :success}})
  end

  def test_evaluate_value_in
    cond = {from: :a, value: {in: ["prod", "staging"]}}
    assert Condition.evaluate(cond, {a: {value: "prod", status: :success}})
    refute Condition.evaluate(cond, {a: {value: "dev", status: :success}})
  end

  def test_evaluate_value_present_with_string
    cond = {from: :a, value: {present: true}}
    assert Condition.evaluate(cond, {a: {value: "hello", status: :success}})
    refute Condition.evaluate(cond, {a: {value: "", status: :success}})
    refute Condition.evaluate(cond, {a: {value: nil, status: :success}})
  end

  def test_evaluate_value_present_with_non_empty_checkable
    cond = {from: :a, value: {present: true}}
    assert Condition.evaluate(cond, {a: {value: [1], status: :success}})
    refute Condition.evaluate(cond, {a: {value: [], status: :success}})
  end

  def test_evaluate_value_present_with_non_emptyable
    cond = {from: :a, value: {present: true}}
    assert Condition.evaluate(cond, {a: {value: 42, status: :success}})
  end

  def test_evaluate_value_nil
    cond = {from: :a, value: {nil: true}}
    assert Condition.evaluate(cond, {a: {value: nil, status: :success}})
    refute Condition.evaluate(cond, {a: {value: "x", status: :success}})
  end

  def test_evaluate_value_matches
    cond = Condition.normalize({from: :a, value: {matches: "^prod"}})
    assert Condition.evaluate(cond, {a: {value: "production", status: :success}})
    refute Condition.evaluate(cond, {a: {value: "staging", status: :success}})
  end

  def test_evaluate_value_matches_accepts_legacy_string_pattern
    cond = {from: :a, value: {matches: "^prod"}}
    assert Condition.evaluate(cond, {a: {value: "production", status: :success}})
    refute Condition.evaluate(cond, {a: {value: "staging", status: :success}})
  end

  def test_evaluate_value_matches_non_string
    cond = Condition.normalize({from: :a, value: {matches: "^prod"}})
    refute Condition.evaluate(cond, {a: {value: 42, status: :success}})
  end

  def test_evaluate_status_and_value_both_must_match
    cond = {from: :a, status: :success, value: {equals: "ok"}}
    assert Condition.evaluate(cond, {a: {value: "ok", status: :success}})
    refute Condition.evaluate(cond, {a: {value: "ok", status: :skipped}})
    refute Condition.evaluate(cond, {a: {value: "bad", status: :success}})
  end

  def test_evaluate_all
    cond = {all: [
      {from: :a, status: :success},
      {from: :b, status: :success}
    ]}
    ctx = {a: {value: nil, status: :success}, b: {value: nil, status: :success}}
    assert Condition.evaluate(cond, ctx)

    ctx_fail = {a: {value: nil, status: :success}, b: {value: nil, status: :skipped}}
    refute Condition.evaluate(cond, ctx_fail)
  end

  def test_evaluate_any
    cond = {any: [
      {from: :a, status: :success},
      {from: :b, status: :success}
    ]}
    ctx = {a: {value: nil, status: :skipped}, b: {value: nil, status: :success}}
    assert Condition.evaluate(cond, ctx)

    ctx_fail = {a: {value: nil, status: :skipped}, b: {value: nil, status: :skipped}}
    refute Condition.evaluate(cond, ctx_fail)
  end

  def test_evaluate_not
    cond = {not: {from: :a, status: :skipped}}
    assert Condition.evaluate(cond, {a: {value: nil, status: :success}})
    refute Condition.evaluate(cond, {a: {value: nil, status: :skipped}})
  end

  def test_evaluate_nested_tree
    cond = {all: [
      {any: [{from: :a, status: :success}, {from: :b, status: :success}]},
      {not: {from: :c, status: :skipped}}
    ]}
    ctx = {
      a: {value: nil, status: :skipped},
      b: {value: nil, status: :success},
      c: {value: nil, status: :success}
    }
    assert Condition.evaluate(cond, ctx)
  end

  # --- validate ---

  def test_validate_nil_returns_empty
    graph = build_graph(:a)
    assert_empty Condition.validate(nil, node_name: :a, graph: graph)
  end

  def test_validate_callable_returns_empty
    graph = build_graph(:a)
    assert_empty Condition.validate(->(_) { true }, node_name: :a, graph: graph)
  end

  def test_validate_valid_reference
    graph = build_graph(:a, :b, edges: [[:a, :b]])
    errors = Condition.validate({from: :a, status: :success}, node_name: :b, graph: graph)
    assert_empty errors
  end

  def test_validate_rejects_non_dependency_reference
    graph = build_graph(:a, :b, :c, edges: [[:a, :b]])
    errors = Condition.validate({from: :c, status: :success}, node_name: :b, graph: graph)
    assert_equal 1, errors.size
    assert_match(/only direct dependencies/, errors.first)
  end

  def test_validate_rejects_reference_when_no_dependencies
    graph = build_graph(:a, :b)
    errors = Condition.validate({from: :a, status: :success}, node_name: :b, graph: graph)
    assert_equal 1, errors.size
    assert_match(/no direct dependencies/, errors.first)
  end

  def test_validate_nested_tree_with_bad_reference
    graph = build_graph(:a, :b, :c, edges: [[:a, :c]])
    cond = {all: [
      {from: :a, status: :success},
      {from: :b, status: :success}
    ]}
    errors = Condition.validate(cond, node_name: :c, graph: graph)
    assert_equal 1, errors.size
    assert_match(/\bb\b/, errors.first)
  end

  def test_validate_bang_raises_on_error
    graph = build_graph(:a, :b)
    assert_raises(DAG::ValidationError) do
      Condition.validate!({from: :a, status: :success}, node_name: :b, graph: graph)
    end
  end

  def test_validate_bang_returns_canonical_condition_on_success
    graph = build_graph(:a, :b, edges: [[:a, :b]])
    condition = {from: :a, status: :success}
    result = Condition.validate!(condition, node_name: :b, graph: graph)
    assert_same condition, result
  end

  # --- dumpable ---

  def test_dumpable_nil_returns_nil
    assert_nil Condition.dumpable(nil)
  end

  def test_dumpable_leaf
    result = Condition.dumpable({from: :a, status: :success, value: {equals: "ok"}})
    assert_equal({"from" => "a", "status" => "success", "value" => {"equals" => "ok"}}, result)
  end

  def test_dumpable_logical_operators
    result = Condition.dumpable({all: [
      {from: :a, status: :success},
      {not: {from: :b, status: :skipped}}
    ]})
    assert_equal 2, result["all"].size
    assert result["all"][1].key?("not")
  end

  def test_dumpable_rejects_callable
    assert_raises(DAG::SerializationError) do
      Condition.dumpable(->(_) { true })
    end
  end

  def test_dumpable_round_trip
    original = {all: [
      {from: :a, status: :success},
      {from: :b, value: {matches: "^ok"}}
    ]}
    dumped = Condition.dumpable(original)
    reloaded = Condition.normalize(dumped)
    assert_equal :a, reloaded[:all][0][:from]
    assert_equal :b, reloaded[:all][1][:from]
    assert_equal "^ok", dumped["all"][1]["value"]["matches"]
    assert_instance_of Regexp, reloaded[:all][1][:value][:matches]
    assert_equal "^ok", reloaded[:all][1][:value][:matches].source
  end

  # --- rename_from ---

  def test_rename_from_rewrites_leaf
    cond = {from: :old, status: :success}
    result = Condition.rename_from(cond, :old, :new)
    assert_equal :new, result[:from]
    assert_equal :success, result[:status]
  end

  def test_rename_from_ignores_unrelated_leaf
    cond = {from: :other, status: :success}
    result = Condition.rename_from(cond, :old, :new)
    assert_equal :other, result[:from]
  end

  def test_rename_from_rewrites_nested_tree
    cond = {all: [
      {from: :old, status: :success},
      {not: {from: :old, value: {equals: "ok"}}},
      {from: :keep, status: :success}
    ]}
    result = Condition.rename_from(cond, :old, :new)
    assert_equal :new, result[:all][0][:from]
    assert_equal :new, result[:all][1][:not][:from]
    assert_equal :keep, result[:all][2][:from]
  end

  def test_rename_from_rewrites_any
    cond = {any: [{from: :old, status: :success}, {from: :keep, status: :success}]}
    result = Condition.rename_from(cond, :old, :new)
    assert_equal :new, result[:any][0][:from]
    assert_equal :keep, result[:any][1][:from]
  end

  def test_rename_from_nil_returns_nil
    assert_nil Condition.rename_from(nil, :old, :new)
  end

  def test_rename_from_callable_passes_through
    callable = ->(x) { x }
    assert_same callable, Condition.rename_from(callable, :old, :new)
  end

  # --- callable? ---

  def test_callable_with_lambda
    assert Condition.callable?(->(x) { x })
  end

  def test_callable_with_proc
    assert Condition.callable?(proc { |x| x })
  end

  def test_callable_with_hash
    refute Condition.callable?({from: :a, status: :success})
  end

  def test_callable_with_nil
    refute Condition.callable?(nil)
  end

  private

  def build_graph(*nodes, edges: [])
    g = DAG::Graph.new
    nodes.each { |n| g.add_node(n) }
    edges.each { |from, to| g.add_edge(from, to) }
    g
  end
end
