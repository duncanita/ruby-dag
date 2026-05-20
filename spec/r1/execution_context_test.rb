# frozen_string_literal: true

require_relative "../test_helper"

class ExecutionContextTest < Minitest::Test
  cover DAG::ExecutionContext

  def test_from_freezes_inputs_deeply
    ctx = DAG::ExecutionContext.from(a: {b: [1, 2]})
    assert ctx.frozen?
    assert ctx[:a].frozen?
    assert ctx[:a][:b].frozen?
  end

  def test_from_nil_returns_empty_context
    ctx = DAG::ExecutionContext.from(nil)

    assert_equal true, ctx.empty?
    assert_equal({}, ctx.to_h)
  end

  def test_empty_predicate_is_false_for_non_empty_context
    ctx = DAG::ExecutionContext.from(a: 1)

    assert_equal false, ctx.empty?
  end

  def test_size_counts_entries
    assert_equal 0, DAG::ExecutionContext.from(nil).size
    assert_equal 2, DAG::ExecutionContext.from(a: 1, b: 2).size
  end

  def test_merge_returns_new_instance_without_mutating
    ctx = DAG::ExecutionContext.from(x: 1)
    merged = ctx.merge(y: 2)

    assert_equal({x: 1}, ctx.to_h)
    assert_equal({x: 1, y: 2}, merged.to_h)
    assert_instance_of DAG::ExecutionContext, merged
    refute_same ctx, merged
  end

  def test_merge_nil_or_empty_patch_returns_self
    ctx = DAG::ExecutionContext.from(x: 1)

    assert_same ctx, ctx.merge(nil)
    assert_same ctx, ctx.merge({})
  end

  def test_to_h_returns_fresh_dup
    ctx = DAG::ExecutionContext.from(a: [1, 2])
    snapshot = ctx.to_h
    snapshot[:a] << 3
    assert_equal [1, 2], ctx[:a]
  end

  def test_from_rejects_non_json_safe
    error = assert_raises(ArgumentError) { DAG::ExecutionContext.from(t: Time.now) }

    assert_includes error.message, "$root.t"
  end

  def test_dig_and_fetch
    ctx = DAG::ExecutionContext.from(a: {b: 42})
    assert_equal 42, ctx.dig(:a, :b)
    assert_equal({b: 42}, ctx.fetch(:a))
    assert_equal :missing, ctx.fetch(:nope, :missing)
  end

  def test_fetch_forwards_missing_key_block
    ctx = DAG::ExecutionContext.from(a: 1)

    assert_equal "missing nope", ctx.fetch(:nope) { |key| "missing #{key}" }
  end

  def test_bracket_returns_nil_for_missing_key
    ctx = DAG::ExecutionContext.from(a: 1)

    assert_nil ctx[:missing]
  end

  def test_key_predicate
    ctx = DAG::ExecutionContext.from(a: 1)

    assert_equal true, ctx.key?(:a)
    assert_equal false, ctx.key?(:missing)
  end

  def test_each_yields_context_pairs
    ctx = DAG::ExecutionContext.from(a: 1, b: 2)
    pairs = []

    returned = ctx.each { |key, value| pairs << [key, value] }

    assert_equal({a: 1, b: 2}, returned)
    assert_equal [[:a, 1], [:b, 2]], pairs
  end

  def test_each_returns_enumerator_without_block
    ctx = DAG::ExecutionContext.from(a: 1)

    assert_equal [[:a, 1]], ctx.each.to_a
  end

  def test_equality_is_structural
    a = DAG::ExecutionContext.from(x: 1)
    b = DAG::ExecutionContext.from(x: 1)
    assert_equal a, b
    refute_equal a, DAG::ExecutionContext.from(x: 2)
  end

  def test_hash_is_structural
    a = DAG::ExecutionContext.from(x: 1)
    b = DAG::ExecutionContext.from(x: 1)

    assert_kind_of Integer, a.hash
    assert_equal a.hash, b.hash
    refute_equal a.hash, DAG::ExecutionContext.from(x: 2).hash
  end

  def test_equality_accepts_execution_context_subclasses
    subclass = Class.new(DAG::ExecutionContext)
    base = DAG::ExecutionContext.from(x: 1)
    derived = subclass.new(x: 1)

    assert_equal base, derived
  end

  def test_equality_rejects_non_context_with_matching_internal_data
    context = DAG::ExecutionContext.from(x: 1)
    impostor = Object.new
    impostor.instance_variable_set(:@data, context.to_h.freeze)

    refute_equal context, impostor
  end

  def test_inspect_lists_keys
    context = DAG::ExecutionContext.from(a: 1, b: 2)

    assert_equal "#<DAG::ExecutionContext keys=[:a, :b]>", context.inspect
    assert_equal context.inspect, context.to_s
  end
end
