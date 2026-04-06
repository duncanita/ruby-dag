# frozen_string_literal: true

require_relative "test_helper"

class ResultTest < Minitest::Test
  # --- Success behavior ---

  def test_success_is_successful
    assert DAG::Success.new(value: 42).success?
    refute DAG::Success.new(value: 42).failure?
  end

  def test_success_carries_value
    assert_equal 42, DAG::Success.new(value: 42).value
  end

  def test_success_has_no_error
    assert_nil DAG::Success.new(value: 42).error
  end

  def test_success_chains_with_and_then
    result = DAG::Success.new(value: 10)
      .and_then { |v| DAG::Success.new(value: v * 2) }
      .and_then { |v| DAG::Success.new(value: v + 1) }

    assert_equal 21, result.value
  end

  def test_success_transforms_with_map
    assert_equal 15, DAG::Success.new(value: 5).map { |v| v * 3 }.value
  end

  def test_success_ignores_map_error
    result = DAG::Success.new(value: 42).map_error { |e| "wrapped: #{e}" }
    assert_equal 42, result.value
  end

  def test_success_unwraps
    assert_equal 42, DAG::Success.new(value: 42).unwrap!
  end

  def test_success_value_or_returns_value
    assert_equal 42, DAG::Success.new(value: 42).value_or(0)
  end

  def test_success_to_h
    assert_equal({status: :success, value: 42}, DAG::Success.new(value: 42).to_h)
  end

  def test_success_inspect
    assert_equal "Success(42)", DAG::Success.new(value: 42).inspect
  end

  def test_success_includes_result_marker
    assert_kind_of DAG::Result, DAG::Success.new(value: 42)
  end

  # --- Failure behavior ---

  def test_failure_is_not_successful
    refute DAG::Failure.new(error: "boom").success?
    assert DAG::Failure.new(error: "boom").failure?
  end

  def test_failure_carries_error
    assert_equal "boom", DAG::Failure.new(error: "boom").error
  end

  def test_failure_has_no_value
    assert_nil DAG::Failure.new(error: "boom").value
  end

  def test_failure_short_circuits_and_then
    result = DAG::Success.new(value: 10)
      .and_then { |_v| DAG::Failure.new(error: "broken") }
      .and_then { |v| DAG::Success.new(value: v + 1) }

    assert result.failure?
    assert_equal "broken", result.error
  end

  def test_failure_ignores_map
    result = DAG::Failure.new(error: "err").map { |v| v * 3 }
    assert_equal "err", result.error
  end

  def test_failure_transforms_with_map_error
    result = DAG::Failure.new(error: "err").map_error { |e| "wrapped: #{e}" }
    assert_equal "wrapped: err", result.error
  end

  def test_failure_unwrap_raises
    assert_raises(RuntimeError) { DAG::Failure.new(error: "nope").unwrap! }
  end

  def test_failure_value_or_returns_default
    assert_equal 0, DAG::Failure.new(error: "err").value_or(0)
  end

  def test_failure_to_h
    assert_equal({status: :failure, error: "boom"}, DAG::Failure.new(error: "boom").to_h)
  end

  def test_failure_inspect
    assert_equal 'Failure("boom")', DAG::Failure.new(error: "boom").inspect
  end

  def test_failure_includes_result_marker
    assert_kind_of DAG::Result, DAG::Failure.new(error: "boom")
  end

  # --- Immutability ---

  def test_success_is_frozen
    assert DAG::Success.new(value: 42).frozen?
  end

  def test_failure_is_frozen
    assert DAG::Failure.new(error: "err").frozen?
  end

  # --- Nil values ---

  def test_success_with_nil_value
    result = DAG::Success.new(value: nil)
    assert result.success?
    assert_nil result.value
  end

  def test_failure_with_nil_error
    result = DAG::Failure.new(error: nil)
    assert result.failure?
    assert_nil result.error
  end
end
