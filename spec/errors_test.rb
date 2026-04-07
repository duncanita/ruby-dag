# frozen_string_literal: true

require_relative "test_helper"

class ErrorsTest < Minitest::Test
  def test_all_errors_inherit_from_dag_error
    [
      DAG::CycleError,
      DAG::DuplicateNodeError,
      DAG::UnknownNodeError,
      DAG::ValidationError,
      DAG::SerializationError
    ].each do |klass|
      assert klass < DAG::Error, "#{klass} should inherit from DAG::Error"
    end
  end

  def test_dag_error_inherits_from_standard_error
    assert DAG::Error < StandardError
  end

  def test_validation_error_carries_errors_array
    error = DAG::ValidationError.new(["problem 1", "problem 2"])
    assert_equal ["problem 1", "problem 2"], error.errors
    assert_equal "problem 1; problem 2", error.message
  end

  def test_validation_error_wraps_single_string
    error = DAG::ValidationError.new("single problem")
    assert_equal ["single problem"], error.errors
  end
end
