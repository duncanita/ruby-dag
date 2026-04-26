# frozen_string_literal: true

require_relative "../test_helper"

class ExecutionContextTest < Minitest::Test
  def test_from_freezes_inputs_deeply
    ctx = DAG::ExecutionContext.from(a: {b: [1, 2]})
    assert ctx.frozen?
    assert ctx[:a].frozen?
    assert ctx[:a][:b].frozen?
  end

  def test_merge_returns_new_instance_without_mutating
    ctx = DAG::ExecutionContext.from(x: 1)
    merged = ctx.merge(y: 2)

    assert_equal({x: 1}, ctx.to_h)
    assert_equal({x: 1, y: 2}, merged.to_h)
    refute_same ctx, merged
  end

  def test_to_h_returns_fresh_dup
    ctx = DAG::ExecutionContext.from(a: [1, 2])
    snapshot = ctx.to_h
    snapshot[:a] << 3
    assert_equal [1, 2], ctx[:a]
  end

  def test_from_rejects_non_json_safe
    assert_raises(ArgumentError) { DAG::ExecutionContext.from(t: Time.now) }
  end

  def test_dig_and_fetch
    ctx = DAG::ExecutionContext.from(a: {b: 42})
    assert_equal 42, ctx.dig(:a, :b)
    assert_equal({b: 42}, ctx.fetch(:a))
    assert_equal :missing, ctx.fetch(:nope, :missing)
  end

  def test_equality_is_structural
    a = DAG::ExecutionContext.from(x: 1)
    b = DAG::ExecutionContext.from(x: 1)
    assert_equal a, b
    refute_equal a, DAG::ExecutionContext.from(x: 2)
  end
end
