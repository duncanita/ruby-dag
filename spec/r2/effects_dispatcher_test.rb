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
      clock: SequenceClock.new(1_000, 1_501, 1_502),
      owner_id: "worker",
      lease_ms: 500
    )

    report = dispatcher.tick(limit: 1)

    assert_equal [effect.id], report.claimed.map(&:id)
    assert_empty report.succeeded
    assert_equal :stale_lease, report.errors.first[:code]
    assert_equal :dispatching, storage.list_effects_for_attempt(attempt_id: effect.attempt_id).first.status
  end

  def test_stale_lease_emits_durable_diagnostic_event
    storage = DAG::Adapters::Memory::Storage.new
    effect = commit_waiting_effect(storage, node_id: :a, effect_type: "success")
    seq_before = storage.read_events(workflow_id: effect.workflow_id).last.seq
    dispatcher = DAG::Effects::Dispatcher.new(
      storage: storage,
      handlers: {"success" => ->(_record) { DAG::Effects::HandlerResult.succeeded(result: {ok: true}) }},
      clock: SequenceClock.new(1_000, 1_501, 1_502),
      owner_id: "worker",
      lease_ms: 500
    )

    dispatcher.tick(limit: 1)

    new_events = storage.read_events(workflow_id: effect.workflow_id, after_seq: seq_before)
    stale_event = new_events.find { |e| e.type == :effect_dispatch_stale_lease }
    refute_nil stale_event, "expected an :effect_dispatch_stale_lease event in the durable log"
    assert_equal effect.workflow_id, stale_event.workflow_id
    assert_equal 1, stale_event.revision
    assert_equal :a, stale_event.node_id
    assert_equal effect.attempt_id, stale_event.attempt_id
    assert_equal 1_502, stale_event.at_ms
    payload = stale_event.payload
    assert_equal :stale_lease, payload[:code]
    assert_equal effect.id, payload[:effect_id]
    assert_equal effect.ref, payload[:ref]
    assert_equal "success", payload[:type]
    assert_equal "worker", payload[:lease_owner]
    assert_equal 1_500, payload[:lease_until_ms]
    assert_kind_of String, payload[:message]
  end

  # ----- V1.3 parallelism: --------------------------------------------------

  def test_parallelism_default_one_preserves_serial_max_in_flight
    storage = DAG::Adapters::Memory::Storage.new
    4.times { |n| commit_waiting_effect(storage, node_id: :"n#{n}", effect_type: "success", effect_key: "k#{n}") }
    handler = IntervalRecordingHandler.new(sleep_seconds: 0.02)
    dispatcher = build_dispatcher(storage, handlers: {"success" => handler})

    dispatcher.tick(limit: 4)

    assert_equal 1, handler.max_concurrent
    assert_equal 4, handler.intervals.size
  end

  def test_parallelism_above_one_caps_workers_in_flight_to_parallelism
    storage = TestThreadSafeMemoryStorage.new
    6.times { |n| commit_waiting_effect(storage, node_id: :"n#{n}", effect_type: "success", effect_key: "k#{n}") }
    handler = IntervalRecordingHandler.new(sleep_seconds: 0.03)
    dispatcher = build_dispatcher(storage, handlers: {"success" => handler}, parallelism: 3)

    dispatcher.tick(limit: 6)

    # Bounded concurrency: pool size strictly capped at parallelism.
    assert_operator handler.max_concurrent, :<=, 3,
      "max_concurrent=#{handler.max_concurrent} exceeds parallelism cap"
    # Sanity: we actually parallelized something rather than running serial.
    assert_operator handler.max_concurrent, :>=, 2,
      "expected at least 2 handlers in flight together; got #{handler.max_concurrent}"
    assert_equal 6, handler.intervals.size
  end

  def test_parallelism_above_one_preserves_collection_order
    storage = TestThreadSafeMemoryStorage.new
    effects = 5.times.map { |n|
      commit_waiting_effect(storage, node_id: :"n#{n}",
        effect_type: (n.even? ? "success" : "fail"), effect_key: "k#{n}")
    }
    handler_success = ->(record) {
      sleep((record.id.bytes.last % 5) * 0.005)
      DAG::Effects::HandlerResult.succeeded(result: {id: record.id})
    }
    handler_fail = ->(record) {
      sleep((record.id.bytes.last % 5) * 0.005)
      DAG::Effects::HandlerResult.failed(error: {code: :nope, id: record.id}, retriable: false)
    }
    dispatcher = build_dispatcher(storage,
      handlers: {"success" => handler_success, "fail" => handler_fail},
      parallelism: 4)

    report = dispatcher.tick(limit: 5)

    claimed_ids = report.claimed.map(&:id)
    assert_equal effects.map(&:id), claimed_ids, "claim order should match commit order"
    succeeded_ids = report.succeeded.map(&:id)
    failed_ids = report.failed.map(&:id)
    assert_equal subsequence(claimed_ids, succeeded_ids), succeeded_ids,
      "succeeded should be a subsequence of claimed in original order"
    assert_equal subsequence(claimed_ids, failed_ids), failed_ids,
      "failed should be a subsequence of claimed in original order"
  end

  # Custom non-StandardError class used to verify that exceptions outside
  # the StandardError tree (which `invoke_handler` deliberately catches)
  # propagate from worker threads via `Thread#value` after `join`.
  # standard:disable Lint/InheritException
  class WorkerPropagationError < Exception; end
  # standard:enable Lint/InheritException

  def test_parallelism_above_one_propagates_unexpected_worker_exceptions
    storage = TestThreadSafeMemoryStorage.new
    3.times { |n| commit_waiting_effect(storage, node_id: :"n#{n}", effect_type: "boom", effect_key: "k#{n}") }
    boomer = ->(_record) { raise WorkerPropagationError, "non-StandardError must propagate" }
    dispatcher = build_dispatcher(storage, handlers: {"boom" => boomer}, parallelism: 2)

    error = silencing_stderr { assert_raises(WorkerPropagationError) { dispatcher.tick(limit: 3) } }
    assert_match(/non-StandardError/, error.message)
  end

  def test_parallelism_above_one_with_memory_storage_raises_argument_error
    storage = DAG::Adapters::Memory::Storage.new
    handlers = {"success" => ->(_record) { DAG::Effects::HandlerResult.succeeded(result: {}) }}

    error = assert_raises(ArgumentError) do
      build_dispatcher(storage, handlers: handlers, parallelism: 4)
    end
    assert_match(/thread_safe_for_dispatch\?/, error.message)
  end

  def test_parallelism_validates_positive_integer
    storage = DAG::Adapters::Memory::Storage.new
    handlers = {"success" => ->(_record) { DAG::Effects::HandlerResult.succeeded(result: {}) }}

    assert_raises(ArgumentError) { build_dispatcher(storage, handlers: handlers, parallelism: 0) }
    assert_raises(ArgumentError) { build_dispatcher(storage, handlers: handlers, parallelism: -1) }
    assert_raises(ArgumentError) { build_dispatcher(storage, handlers: handlers, parallelism: 1.5) }
  end

  private

  def build_dispatcher(storage, handlers:, unknown_handler_policy: :terminal_failure,
    parallelism: 1, clock: FixedClock[now_ms: 1_000])
    DAG::Effects::Dispatcher.new(
      storage: storage,
      handlers: handlers,
      clock: clock,
      owner_id: "worker",
      lease_ms: 500,
      unknown_handler_policy: unknown_handler_policy,
      parallelism: parallelism
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

    def append_event(workflow_id:, event:)
      (@events ||= []) << event
      event
    end

    attr_reader :events
  end

  # Memory storage that opts into the `parallelism > 1` contract for tests.
  # Memory itself is single-process per Roadmap §2.4 and intentionally does
  # not declare `thread_safe_for_dispatch?` in production. This subclass is
  # test-scope only: we exercise the dispatcher's parallel_map with bounded
  # batches and per-record-isolated state, where Memory's plain-Hash bookkeeping
  # plus CRuby's GVL is sufficient. Production parallelism uses durable
  # adapters that bind every dispatcher-touched method to a transaction.
  class TestThreadSafeMemoryStorage < DAG::Adapters::Memory::Storage
    def thread_safe_for_dispatch?
      true
    end
  end

  # Records each handler invocation's [entered_at_ms, exited_at_ms] interval
  # in a per-record slot, so tests can compute the maximum number of handlers
  # in flight at any moment ex post from the merged interval set. Avoids
  # needing thread synchronization primitives in the test (writes are to
  # disjoint keys).
  class IntervalRecordingHandler
    attr_reader :intervals

    def initialize(sleep_seconds:)
      @sleep_seconds = sleep_seconds
      @intervals = {}
    end

    def call(record)
      entered = monotonic_ns
      sleep @sleep_seconds
      exited = monotonic_ns
      @intervals[record.id] = [entered, exited]
      DAG::Effects::HandlerResult.succeeded(result: {id: record.id})
    end

    # Counts the maximum number of handlers in flight at any moment by
    # sweeping start/end events. End-events sort before start-events at
    # equal timestamps so that two handlers whose intervals abut at the
    # same nanosecond are not falsely reported as concurrent.
    def max_concurrent
      events = []
      @intervals.each_value do |entered, exited|
        events << [exited, 0, :end]
        events << [entered, 1, :start]
      end
      events.sort!
      max = 0
      cur = 0
      delta = {start: 1, end: -1}
      events.each do |_, _, kind|
        cur += delta.fetch(kind)
        max = cur if cur > max
      end
      max
    end

    private

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end
  end

  # Suppresses Ruby's "Thread terminated with exception (report_on_exception
  # is true)" diagnostic noise so the test output stays clean while still
  # asserting that the exception propagates out of `tick`.
  def silencing_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end

  def subsequence(full, candidate)
    indices = candidate.map { |id| full.index(id) }
    return candidate if indices.none?(&:nil?) && indices == indices.sort

    candidate.select { |id| full.include?(id) }.sort_by { |id| full.index(id) }
  end
end
