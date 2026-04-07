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

  def test_success_unwraps
    assert_equal 42, DAG::Success.new(value: 42).unwrap!
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

  def test_failure_unwrap_raises
    assert_raises(RuntimeError) { DAG::Failure.new(error: "nope").unwrap! }
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

  # --- and_then enforces Result return ---

  def test_success_and_then_enforces_result
    error = assert_raises(TypeError) do
      DAG::Success.new(value: 1).and_then { |v| v + 1 }
    end
    assert_includes error.message, "and_then"
    assert_includes error.message, "Integer"
  end

  # --- recover ---

  def test_success_recover_is_noop
    result = DAG::Success.new(value: 42).recover { |_| DAG::Success.new(value: 0) }
    assert_equal 42, result.value
  end

  def test_failure_recover_to_success
    result = DAG::Failure.new(error: "boom").recover { |_| DAG::Success.new(value: :ok) }
    assert result.success?
    assert_equal :ok, result.value
  end

  def test_failure_recover_to_other_failure
    result = DAG::Failure.new(error: "boom").recover { |e| DAG::Failure.new(error: "wrapped: #{e}") }
    assert result.failure?
    assert_equal "wrapped: boom", result.error
  end

  def test_failure_recover_enforces_result
    error = assert_raises(TypeError) do
      DAG::Failure.new(error: "boom").recover { |_| 42 }
    end
    assert_includes error.message, "recover"
  end

  # --- Result.try ---

  def test_try_success
    result = DAG::Result.try { 1 + 1 }
    assert result.success?
    assert_equal 2, result.value
  end

  def test_try_failure_on_standard_error
    result = DAG::Result.try { raise ArgumentError, "bad" }
    assert result.failure?
    assert_includes result.error, "ArgumentError"
    assert_includes result.error, "bad"
  end

  def test_try_does_not_catch_outside_default
    assert_raises(SystemExit) { DAG::Result.try { exit } }
  end

  def test_try_with_narrower_error_class
    result = DAG::Result.try(error_class: ArgumentError) { raise ArgumentError, "bad" }
    assert result.failure?

    assert_raises(KeyError) do
      DAG::Result.try(error_class: ArgumentError) { raise KeyError, "missing" }
    end
  end
end
