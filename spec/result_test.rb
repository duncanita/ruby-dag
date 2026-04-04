# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/dag"

class ResultTest < Minitest::Test
  def test_success_holds_value
    result = DAG::Result.success(42)
    assert result.success?
    refute result.failure?
    assert_equal 42, result.value
  end

  def test_failure_holds_error
    result = DAG::Result.failure("boom")
    assert result.failure?
    refute result.success?
    assert_equal "boom", result.error
  end

  def test_and_then_chains_on_success
    result = DAG::Result.success(10)
      .and_then { |v| DAG::Result.success(v * 2) }
      .and_then { |v| DAG::Result.success(v + 1) }

    assert_equal 21, result.value
  end

  def test_and_then_stops_at_first_failure
    result = DAG::Result.success(10)
      .and_then { |_v| DAG::Result.failure("broken") }
      .and_then { |v| DAG::Result.success(v + 1) }

    assert result.failure?
    assert_equal "broken", result.error
  end

  def test_map_transforms_success_value
    result = DAG::Result.success(5).map { |v| v * 3 }
    assert_equal 15, result.value
  end

  def test_map_passes_through_failure
    result = DAG::Result.failure("err").map { |v| v * 3 }
    assert result.failure?
    assert_equal "err", result.error
  end

  def test_unwrap_returns_value_on_success
    assert_equal 42, DAG::Result.success(42).unwrap!
  end

  def test_unwrap_raises_on_failure
    assert_raises(RuntimeError) { DAG::Result.failure("nope").unwrap! }
  end

  def test_value_or_returns_value_on_success
    assert_equal 42, DAG::Result.success(42).value_or(0)
  end

  def test_value_or_returns_default_on_failure
    assert_equal 0, DAG::Result.failure("err").value_or(0)
  end
end
