# frozen_string_literal: true

require_relative "../test_helper"

class R0TypesAreDeepFrozenTest < Minitest::Test
  def test_success_bracket_constructor_deep_freezes_nested_values
    result = DAG::Success[value: {a: []}]

    assert result.frozen?
    assert_raises(FrozenError) { result.value[:a] << 1 }
  end

  def test_success_new_constructor_deep_freezes_nested_values
    result = DAG::Success.new(value: {a: []})

    assert result.frozen?
    assert_raises(FrozenError) { result.value[:a] << 1 }
  end

  def test_waiting_accepts_integer_not_before_ms
    waiting = DAG::Waiting[reason: :rate_limited, not_before_ms: 1_700_000_000_000]

    assert_equal :rate_limited, waiting.reason
    assert_equal 1_700_000_000_000, waiting.not_before_ms
  end

  def test_waiting_rejects_time_not_before_ms
    assert_raises(ArgumentError) do
      DAG::Waiting[reason: :rate_limited, not_before_ms: Time.now]
    end
  end

  def test_frozen_copy_preserves_frozen_strings_and_isolates_mutable_strings
    frozen = (+"already").freeze
    mutable = +"mutable"

    assert_same frozen, DAG.frozen_copy(frozen)
    copied = DAG.frozen_copy(mutable)
    mutable << "-changed"

    assert_equal "mutable", copied
    assert copied.frozen?
  end

  def test_event_copies_and_freezes_coordinate_strings
    workflow_id = +"wf-1"
    node_id = +"node-a"
    attempt_id = +"wf-1/1"

    event = DAG::Event[
      type: :node_committed,
      workflow_id: workflow_id,
      revision: 1,
      node_id: node_id,
      attempt_id: attempt_id,
      at_ms: 1_700_000_000_000,
      payload: {}
    ]
    workflow_id << "-mutated"
    node_id << "-mutated"
    attempt_id << "-mutated"

    assert_equal "wf-1", event.workflow_id
    assert_equal "node-a", event.node_id
    assert_equal "wf-1/1", event.attempt_id
    assert event.workflow_id.frozen?
    assert event.node_id.frozen?
    assert event.attempt_id.frozen?
  end
end
