# frozen_string_literal: true

require_relative "../test_helper"

class EffectsDispatcherTest < Minitest::Test
  FixedClock = Data.define(:now_ms) do
    def initialize(now_ms:) = super
  end

  class SequenceClock
    def initialize(*values)
      @values = values
    end

    def now_ms
      @values.shift || raise("clock exhausted")
    end
  end

  def test_tick_claims_at_most_limit_and_marks_success
    storage = DAG::Adapters::Memory::Storage.new
    first = commit_waiting_effect(storage, node_id: :a, effect_key: "first", effect_type: "success")
    second = commit_waiting_effect(storage, node_id: :b, effect_key: "second", effect_type: "success")
    dispatcher = build_dispatcher(storage,
      handlers: {"success" => ->(record) { DAG::Effects::HandlerResult.succeeded(result: {id: record.id}) }})

    report = dispatcher.tick(limit: 1)

    assert_equal [first.id], report.claimed.map(&:id)
    assert_equal [first.id], report.succeeded.map(&:id)
    assert_empty report.failed
    assert_empty report.errors
    assert report.frozen?
    assert report.succeeded.frozen?
    assert_equal :succeeded, storage.list_effects_for_attempt(attempt_id: first.attempt_id).first.status
    assert_equal :reserved, storage.list_effects_for_attempt(attempt_id: second.attempt_id).first.status
  end

  def test_successful_handler_releases_satisfied_waiting_nodes
    storage = DAG::Adapters::Memory::Storage.new
    effect = commit_waiting_effect(storage, node_id: :a, effect_type: "success")
    dispatcher = build_dispatcher(storage,
      handlers: {"success" => ->(_record) { DAG::Effects::HandlerResult.succeeded(result: {ok: true}, external_ref: "ext-1") }})

    report = dispatcher.tick(limit: 1)

    assert_equal :succeeded, report.succeeded.first.status
    assert_equal [{workflow_id: effect.workflow_id, revision: 1, node_id: :a, attempt_id: effect.attempt_id, released_at_ms: 1_000}], report.released
    assert_equal :pending, storage.load_node_states(workflow_id: effect.workflow_id, revision: 1)[:a]
  end

  def test_retriable_handler_failure_marks_failed_retriable_without_release
    storage = DAG::Adapters::Memory::Storage.new
    effect = commit_waiting_effect(storage, node_id: :a, effect_type: "flaky")
    dispatcher = build_dispatcher(storage,
      handlers: {"flaky" => ->(_record) { DAG::Effects::HandlerResult.failed(error: {code: :again}, retriable: true, not_before_ms: 2_000) }})

    report = dispatcher.tick(limit: 1)

    assert_empty report.succeeded
    assert_empty report.released
    failed = report.failed.first
    assert_equal effect.id, failed.id
    assert_equal :failed_retriable, failed.status
    assert_equal 2_000, failed.not_before_ms
    assert_equal :waiting, storage.load_node_states(workflow_id: effect.workflow_id, revision: 1)[:a]
  end

  def test_terminal_handler_failure_marks_failed_terminal_and_releases
    storage = DAG::Adapters::Memory::Storage.new
    effect = commit_waiting_effect(storage, node_id: :a, effect_type: "terminal")
    dispatcher = build_dispatcher(storage,
      handlers: {"terminal" => ->(_record) { DAG::Effects::HandlerResult.failed(error: {code: :nope}, retriable: false) }})

    report = dispatcher.tick(limit: 1)

    failed = report.failed.first
    assert_equal :failed_terminal, failed.status
    assert_equal [{workflow_id: effect.workflow_id, revision: 1, node_id: :a, attempt_id: effect.attempt_id, released_at_ms: 1_000}], report.released
    assert_equal :pending, storage.load_node_states(workflow_id: effect.workflow_id, revision: 1)[:a]
  end

  def test_unknown_handler_defaults_to_terminal_failure
    storage = DAG::Adapters::Memory::Storage.new
    effect = commit_waiting_effect(storage, node_id: :a, effect_type: "missing")
    dispatcher = build_dispatcher(storage, handlers: {})

    report = dispatcher.tick(limit: 1)

    assert_equal :failed_terminal, report.failed.first.status
    assert_equal :unknown_handler, report.failed.first.error[:code]
    assert_equal "missing", report.failed.first.error[:type]
    assert_equal :unknown_handler, report.errors.first[:code]
    assert_equal effect.id, report.errors.first[:effect_id]
  end

  def test_unknown_handler_raise_policy_raises
    storage = DAG::Adapters::Memory::Storage.new
    commit_waiting_effect(storage, node_id: :a, effect_type: "missing")
    dispatcher = build_dispatcher(storage, handlers: {}, unknown_handler_policy: :raise)

    assert_raises(DAG::Effects::UnknownHandlerError) { dispatcher.tick(limit: 1) }
  end

  def test_handler_exception_becomes_retriable_failure
    storage = DAG::Adapters::Memory::Storage.new
    effect = commit_waiting_effect(storage, node_id: :a, effect_type: "raise")
    dispatcher = build_dispatcher(storage,
      handlers: {"raise" => ->(_record) { raise "boom" }})

    report = dispatcher.tick(limit: 1)

    failed = report.failed.first
    assert_equal :failed_retriable, failed.status
    assert_equal :handler_raised, failed.error[:code]
    assert_equal "RuntimeError", failed.error[:class]
    assert_equal "boom", failed.error[:message]
    assert_equal :handler_raised, report.errors.first[:code]
    assert_equal effect.id, report.errors.first[:effect_id]
  end

  def test_handler_bad_return_becomes_retriable_failure
    storage = DAG::Adapters::Memory::Storage.new
    effect = commit_waiting_effect(storage, node_id: :a, effect_type: "bad")
    dispatcher = build_dispatcher(storage,
      handlers: {"bad" => ->(_record) { "not a handler result" }})

    report = dispatcher.tick(limit: 1)

    failed = report.failed.first
    assert_equal :failed_retriable, failed.status
    assert_equal :handler_bad_return, failed.error[:code]
    assert_equal "String", failed.error[:class]
    assert_equal :handler_bad_return, report.errors.first[:code]
    assert_equal effect.id, report.errors.first[:effect_id]
  end

  def test_stale_lease_errors_are_reported_and_tick_continues
    storage = StaleSuccessStorage.new
    first = DAG::Effects::Record[
      id: "effect/1",
      workflow_id: "wf",
      revision: 1,
      node_id: :a,
      attempt_id: "wf/1",
      type: "success",
      key: "first",
      payload: {},
      payload_fingerprint: "fp",
      blocking: true,
      status: :dispatching,
      created_at_ms: 0,
      updated_at_ms: 0,
      lease_owner: "worker",
      lease_until_ms: 2_000
    ]
    second = first.with(id: "effect/2", key: "second")
    storage.claimed = [first, second]
    dispatcher = build_dispatcher(storage,
      handlers: {"success" => ->(_record) { DAG::Effects::HandlerResult.succeeded(result: {ok: true}) }})

    report = dispatcher.tick(limit: 2)

    assert_equal ["effect/2"], report.succeeded.map(&:id)
    assert_equal :stale_lease, report.errors.first[:code]
    assert_equal "effect/1", report.errors.first[:effect_id]
  end

  def test_mark_uses_fresh_time_after_handler
    storage = DAG::Adapters::Memory::Storage.new
    effect = commit_waiting_effect(storage, node_id: :a, effect_type: "success")
    dispatcher = DAG::Effects::Dispatcher.new(
      storage: storage,
      handlers: {"success" => ->(_record) { DAG::Effects::HandlerResult.succeeded(result: {ok: true}) }},
      clock: SequenceClock.new(1_000, 1_501),
      owner_id: "worker",
      lease_ms: 500
    )

    report = dispatcher.tick(limit: 1)

    assert_equal [effect.id], report.claimed.map(&:id)
    assert_empty report.succeeded
    assert_equal :stale_lease, report.errors.first[:code]
    assert_equal :dispatching, storage.list_effects_for_attempt(attempt_id: effect.attempt_id).first.status
  end

  private

  def build_dispatcher(storage, handlers:, unknown_handler_policy: :terminal_failure)
    DAG::Effects::Dispatcher.new(
      storage: storage,
      handlers: handlers,
      clock: FixedClock[now_ms: 1_000],
      owner_id: "worker",
      lease_ms: 500,
      unknown_handler_policy: unknown_handler_policy
    )
  end

  def commit_waiting_effect(storage, node_id:, effect_type:, effect_key: "effect")
    workflow_id = create_workflow(
      storage,
      DAG::Workflow::Definition.new.add_node(node_id, type: :passthrough)
    )
    attempt_id = storage.begin_attempt(
      workflow_id: workflow_id,
      revision: 1,
      node_id: node_id,
      expected_node_state: :pending,
      attempt_number: 1
    )
    intent = DAG::Effects::PreparedIntent[
      workflow_id: workflow_id,
      revision: 1,
      node_id: node_id,
      attempt_id: attempt_id,
      type: effect_type,
      key: effect_key,
      payload: {node: node_id},
      payload_fingerprint: "fp-#{effect_type}-#{effect_key}",
      blocking: true,
      created_at_ms: 1_000
    ]
    storage.commit_attempt(
      attempt_id: attempt_id,
      result: DAG::Waiting[reason: :effect_pending],
      node_state: :waiting,
      event: DAG::Event[
        type: :node_waiting,
        workflow_id: workflow_id,
        revision: 1,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: 1_000,
        payload: {}
      ],
      effects: [intent]
    )
    storage.list_effects_for_attempt(attempt_id: attempt_id).first
  end

  class StaleSuccessStorage
    attr_writer :claimed

    def initialize
      @claimed = []
      @succeeded = false
    end

    def claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:)
      @claimed.first(limit)
    end

    def mark_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:)
      if @succeeded
        @claimed.find { |record| record.id == effect_id }.with(
          status: :succeeded,
          result: result,
          external_ref: external_ref,
          lease_owner: nil,
          lease_until_ms: nil,
          updated_at_ms: now_ms
        )
      else
        @succeeded = true
        raise DAG::Effects::StaleLeaseError, "stale lease"
      end
    end

    def mark_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
      raise "not expected"
    end

    def release_nodes_satisfied_by_effect(effect_id:, now_ms:)
      []
    end
  end
end
