# frozen_string_literal: true

require_relative "../test_helper"

class EffectsValueObjectsTest < Minitest::Test
  SnapshotInput = Data.define(:metadata)

  def test_effect_errors_inherit_from_dag_error
    assert_operator DAG::Effects::IdempotencyConflictError, :<, DAG::Error
    assert_operator DAG::Effects::StaleLeaseError, :<, DAG::Error
    assert_operator DAG::Effects::UnknownEffectError, :<, DAG::Error
    assert_operator DAG::Effects::UnknownHandlerError, :<, DAG::Error
  end

  def test_intent_is_deep_frozen_json_safe_and_has_deterministic_ref
    payload = {args: [{id: 1}]}
    intent = DAG::Effects::Intent[type: "delphi.tool", key: "wf:1", payload: payload, metadata: {source: "test"}]
    payload[:args].first[:id] = 2

    assert intent.frozen?
    assert intent.ref.frozen?
    assert_equal "delphi.tool:wf:1", intent.ref
    assert_equal 1, intent.payload[:args].first[:id]
    assert_raises(FrozenError) { intent.payload[:args] << {id: 3} }
  end

  def test_intent_rejects_non_string_identity_and_non_json_payload
    assert_raises(ArgumentError) { DAG::Effects::Intent[type: :tool, key: "k"] }
    assert_raises(ArgumentError) { DAG::Effects::Intent[type: "tool", key: :k] }
    assert_raises(ArgumentError) { DAG::Effects::Intent[type: "tool", key: "k", payload: {time: Time.now}] }
  end

  def test_prepared_intent_is_deep_frozen_and_derives_ref_from_type_and_key
    prepared = prepared_intent(payload: {items: ["a"]})

    assert prepared.frozen?
    assert prepared.ref.frozen?
    assert_equal "tool:k", prepared.ref
    assert prepared.blocking
    assert_raises(FrozenError) { prepared.payload[:items] << "b" }
    assert_raises(ArgumentError) { prepared_intent(payload: {time: Time.now}) }
  end

  def test_prepared_intent_factory_rejects_ref_kwarg
    assert_raises(ArgumentError) do
      DAG::Effects::PreparedIntent[
        workflow_id: "wf",
        revision: 1,
        node_id: :node,
        attempt_id: "attempt-1",
        type: "tool",
        key: "k",
        payload: {},
        payload_fingerprint: "sha256",
        blocking: true,
        created_at_ms: 123,
        ref: "tool:k"
      ]
    end
  end

  def test_prepared_intent_with_recomputes_ref_when_identity_changes
    prepared = prepared_intent(payload: {items: ["a"]})

    rebuilt_type = prepared.with(type: "other")
    rebuilt_key = prepared.with(key: "other-key")

    assert_equal "other:k", rebuilt_type.ref
    assert_equal "tool:other-key", rebuilt_key.ref
  end

  def test_prepared_intent_can_be_built_from_intent
    intent = DAG::Effects::Intent[type: "tool", key: "k", payload: {items: ["a"]}, metadata: {origin: "step"}]
    prepared = DAG::Effects::PreparedIntent.from_intent(
      intent: intent,
      workflow_id: "wf",
      revision: 1,
      node_id: :node,
      attempt_id: "attempt-1",
      payload_fingerprint: "sha256",
      blocking: true,
      created_at_ms: 123
    )

    assert_equal intent.ref, prepared.ref
    assert_equal intent.payload, prepared.payload
    assert_equal intent.metadata, prepared.metadata
  end

  def test_prepared_intent_from_intent_preserves_explicit_falsy_metadata
    intent = DAG::Effects::Intent[type: "tool", key: "k", metadata: {origin: "step"}]
    prepared = DAG::Effects::PreparedIntent.from_intent(
      intent: intent,
      workflow_id: "wf",
      revision: 1,
      node_id: :node,
      attempt_id: "attempt-1",
      payload_fingerprint: "sha256",
      blocking: true,
      created_at_ms: 123,
      metadata: false
    )

    assert_equal false, prepared.metadata
  end

  def test_record_is_deep_frozen_json_safe_and_exposes_terminal_predicate
    record = effect_record(status: :succeeded, result: {ok: true})

    assert record.frozen?
    assert record.ref.frozen?
    assert record.terminal?
    assert_equal "tool:k", record.ref
    assert_raises(FrozenError) { record.result[:ok] = false }
    assert_raises(ArgumentError) { effect_record(status: :unknown) }
    assert_raises(ArgumentError) { effect_record(status: :succeeded, result: {time: Time.now}) }
  end

  def test_record_with_recomputes_ref_when_identity_changes
    record = effect_record(status: :succeeded, result: {ok: true})

    rebuilt = record.with(type: "other")

    assert_equal "other:k", rebuilt.ref
  end

  def test_record_can_be_built_from_prepared_intent
    prepared = prepared_intent(payload: {items: ["a"]})
    record = DAG::Effects::Record.from_prepared(
      id: "effect-1",
      prepared_intent: prepared,
      status: :reserved,
      updated_at_ms: 124
    )

    assert_equal prepared.ref, record.ref
    assert_equal prepared.payload, record.payload
    assert_equal prepared.metadata, record.metadata
    assert_equal prepared.created_at_ms, record.created_at_ms
  end

  def test_record_from_prepared_preserves_explicit_falsy_metadata
    record = DAG::Effects::Record.from_prepared(
      id: "effect-1",
      prepared_intent: prepared_intent(payload: {}),
      status: :reserved,
      updated_at_ms: 124,
      metadata: false
    )

    assert_equal false, record.metadata
  end

  def test_handler_result_factories_are_immutable_and_typed
    succeeded = DAG::Effects::HandlerResult.succeeded(result: {id: 1}, external_ref: "ext")
    retriable = DAG::Effects::HandlerResult.failed(error: {code: :busy}, retriable: true, not_before_ms: 12)
    terminal = DAG::Effects::HandlerResult.failed(error: {code: :nope}, retriable: false)

    assert succeeded.success?
    refute succeeded.failure?
    assert_equal :succeeded, succeeded.status
    assert_equal :failed_retriable, retriable.status
    assert retriable.retriable?
    assert_equal :failed_terminal, terminal.status
    refute terminal.retriable?
    assert_raises(FrozenError) { succeeded.result[:id] = 2 }
    assert_raises(ArgumentError) { DAG::Effects::HandlerResult.succeeded(result: {time: Time.now}) }
    assert_raises(ArgumentError) { DAG::Effects::HandlerResult.failed(error: {code: :x}, retriable: "false") }
  end

  def test_success_and_waiting_are_backward_compatible_with_empty_effects
    success = DAG::Success[value: 1]
    waiting = DAG::Waiting[reason: :external]

    assert_equal [], success.proposed_effects
    assert_equal [], waiting.proposed_effects
  end

  def test_success_and_waiting_accept_only_effect_intents
    intent = effect_intent
    success = DAG::Success[value: 1, proposed_effects: [intent]]
    waiting = DAG::Waiting[reason: :effect_pending, proposed_effects: [intent]]

    assert_equal [intent], success.proposed_effects
    assert_equal [intent], waiting.proposed_effects
    assert_raises(ArgumentError) { DAG::Success[value: 1, proposed_effects: ["not intent"]] }
    assert_raises(ArgumentError) { DAG::Waiting[reason: :effect_pending, proposed_effects: ["not intent"]] }
  end

  def test_success_map_and_waiting_at_preserve_proposed_effects
    intent = effect_intent
    mapped = DAG::Success[value: 1, proposed_effects: [intent]].map { |value| value + 1 }
    waiting = DAG::Waiting.at(reason: :effect_pending, time: Time.utc(2026, 1, 1), proposed_effects: [intent])

    assert_equal 2, mapped.value
    assert_equal [intent], mapped.proposed_effects
    assert_equal [intent], waiting.proposed_effects
  end

  def test_await_returns_waiting_when_snapshot_is_absent
    intent = effect_intent
    result = DAG::Effects::Await.call(SnapshotInput.new({}), intent, not_before_ms: 10) do
      raise "should not yield"
    end

    assert_kind_of DAG::Waiting, result
    assert_equal :effect_pending, result.reason
    assert_equal 10, result.not_before_ms
    assert_equal [intent], result.proposed_effects
    assert_equal({effects: [intent.ref]}, result.resume_token)
  end

  def test_await_yields_when_snapshot_succeeded
    intent = effect_intent
    input = SnapshotInput.new({effects: {intent.ref => {"status" => "succeeded", "result" => {answer: 42}}}})
    result = DAG::Effects::Await.call(input, intent) do |effect_result|
      DAG::Success[value: effect_result[:answer]]
    end

    assert_kind_of DAG::Success, result
    assert_equal 42, result.value
  end

  def test_await_returns_non_retriable_failure_for_terminal_failure
    intent = effect_intent
    input = SnapshotInput.new({effects: {intent.ref => {status: :failed_terminal, error: {code: :denied}}}})
    result = DAG::Effects::Await.call(input, intent) do
      raise "should not yield"
    end

    assert_kind_of DAG::Failure, result
    refute result.retriable
    assert_equal({code: :denied}, result.error)
    assert_equal({effect_ref: intent.ref}, result.metadata)
  end

  def test_await_returns_waiting_for_retriable_failure
    intent = effect_intent
    record = effect_record(status: :failed_retriable, error: {code: :busy}, not_before_ms: 99)
    result = DAG::Effects::Await.call(SnapshotInput.new({effects: {intent.ref => record}}), intent, not_before_ms: 10) do
      raise "should not yield"
    end

    assert_kind_of DAG::Waiting, result
    assert_equal 99, result.not_before_ms
    assert_equal [intent], result.proposed_effects
  end

  def test_await_requires_continuation_to_return_step_result
    intent = effect_intent
    input = SnapshotInput.new({effects: {intent.ref => {status: :succeeded, result: 1}}})

    assert_raises(TypeError) do
      DAG::Effects::Await.call(input, intent) { |value| value + 1 }
    end
  end

  def test_await_rejects_non_intent_first_argument
    assert_raises(ArgumentError) do
      DAG::Effects::Await.call(SnapshotInput.new({}), "not-an-intent") { |_| nil }
    end
  end

  def test_await_rejects_non_integer_not_before_ms
    assert_raises(ArgumentError) do
      DAG::Effects::Await.call(SnapshotInput.new({}), effect_intent, not_before_ms: 1.5) { |_| nil }
    end
  end

  private

  def effect_intent
    DAG::Effects::Intent[type: "tool", key: "k", payload: {input: 1}]
  end

  def prepared_intent(payload: {})
    DAG::Effects::PreparedIntent[
      workflow_id: "wf",
      revision: 1,
      node_id: :node,
      attempt_id: "attempt-1",
      type: "tool",
      key: "k",
      payload: payload,
      payload_fingerprint: "sha256",
      blocking: true,
      created_at_ms: 123
    ]
  end

  def effect_record(status:, result: nil, error: nil, not_before_ms: nil)
    DAG::Effects::Record[
      id: "effect-1",
      workflow_id: "wf",
      revision: 1,
      node_id: :node,
      attempt_id: "attempt-1",
      type: "tool",
      key: "k",
      payload: {input: 1},
      payload_fingerprint: "sha256",
      blocking: true,
      status: status,
      result: result,
      error: error,
      not_before_ms: not_before_ms,
      created_at_ms: 123,
      updated_at_ms: 124
    ]
  end
end
