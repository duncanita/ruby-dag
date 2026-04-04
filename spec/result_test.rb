# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/dag"

class ResultTest < Minitest::Test
  # --- Success behavior ---

  def test_success_is_successful
    assert DAG::Success(42).success?
    refute DAG::Success(42).failure?
  end

  def test_success_carries_value
    assert_equal 42, DAG::Success(42).value
  end

  def test_success_has_no_error
    assert_nil DAG::Success(42).error
  end

  def test_success_chains_with_and_then
    result = DAG::Success(10)
      .and_then { |v| DAG::Success(v * 2) }
      .and_then { |v| DAG::Success(v + 1) }

    assert_equal 21, result.value
  end

  def test_success_transforms_with_map
    assert_equal 15, DAG::Success(5).map { |v| v * 3 }.value
  end

  def test_success_ignores_map_error
    result = DAG::Success(42).map_error { |e| "wrapped: #{e}" }
    assert_equal 42, result.value
  end

  def test_success_unwraps
    assert_equal 42, DAG::Success(42).unwrap!
  end

  def test_success_value_or_returns_value
    assert_equal 42, DAG::Success(42).value_or(0)
  end

  def test_success_to_h
    assert_equal({ status: :success, value: 42 }, DAG::Success(42).to_h)
  end

  def test_success_inspect
    assert_equal "Success(42)", DAG::Success(42).inspect
  end

  # --- Failure behavior ---

  def test_failure_is_not_successful
    refute DAG::Failure("boom").success?
    assert DAG::Failure("boom").failure?
  end

  def test_failure_carries_error
    assert_equal "boom", DAG::Failure("boom").error
  end

  def test_failure_has_no_value
    assert_nil DAG::Failure("boom").value
  end

  def test_failure_short_circuits_and_then
    result = DAG::Success(10)
      .and_then { |_v| DAG::Failure("broken") }
      .and_then { |v| DAG::Success(v + 1) }

    assert result.failure?
    assert_equal "broken", result.error
  end

  def test_failure_ignores_map
    result = DAG::Failure("err").map { |v| v * 3 }
    assert_equal "err", result.error
  end

  def test_failure_transforms_with_map_error
    result = DAG::Failure("err").map_error { |e| "wrapped: #{e}" }
    assert_equal "wrapped: err", result.error
  end

  def test_failure_unwrap_raises
    assert_raises(RuntimeError) { DAG::Failure("nope").unwrap! }
  end

  def test_failure_value_or_returns_default
    assert_equal 0, DAG::Failure("err").value_or(0)
  end

  def test_failure_to_h
    assert_equal({ status: :failure, error: "boom" }, DAG::Failure("boom").to_h)
  end

  def test_failure_inspect
    assert_equal 'Failure("boom")', DAG::Failure("boom").inspect
  end

  # --- Immutability ---

  def test_success_is_frozen
    assert DAG::Success(42).frozen?
  end

  def test_failure_is_frozen
    assert DAG::Failure("err").frozen?
  end

  # --- Nil values ---

  def test_success_with_nil_value
    result = DAG::Success(nil)
    assert result.success?
    assert_nil result.value
  end

  def test_failure_with_nil_error
    result = DAG::Failure(nil)
    assert result.failure?
    assert_nil result.error
  end
end
