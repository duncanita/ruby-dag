# frozen_string_literal: true

require_relative "../test_helper"

class R0JsonSafetyTest < Minitest::Test
  def test_json_safe_rejects_canonical_key_collisions
    error = assert_raises(ArgumentError) do
      DAG.json_safe!({:a => 1, "a" => 2})
    end

    assert_includes error.message, "canonical key collision"
  end

  def test_json_safe_rejects_time_values
    error = assert_raises(ArgumentError) do
      DAG.json_safe!({deadline: Time.now})
    end

    assert_includes error.message, "non JSON-safe value"
  end

  def test_json_safe_error_paths_are_preserved_for_nested_values
    error = assert_raises(ArgumentError) do
      DAG.json_safe!({items: [{deadline: Time.now}]})
    end

    assert_includes error.message, "$root.items[0].deadline"
  end
end
