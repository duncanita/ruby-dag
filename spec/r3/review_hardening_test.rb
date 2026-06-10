# frozen_string_literal: true

require_relative "../test_helper"

# Pins the helpers and guard branches introduced (or made canonical) by the
# project-review hardening pass: AttemptOrder, EventPublishing, the optional
# Validation helpers, the trusted ExecutionContext#merge path, and the
# defensive branches in StorageState and the dispatcher carriers.
class R3ReviewHardeningTest < Minitest::Test
  FixedClock = Data.define(:now_ms)

  # --- DAG::AttemptOrder -------------------------------------------------

  def test_attempt_order_prefers_higher_attempt_number
    low = {attempt_number: 1, attempt_id: "w/9"}
    high = {attempt_number: 2, attempt_id: "w/1"}

    assert DAG::AttemptOrder.better?(high, low)
    refute DAG::AttemptOrder.better?(low, high)
    assert DAG::AttemptOrder.better?(low, nil)
  end

  def test_attempt_order_breaks_number_ties_by_attempt_id_ascii
    first = {attempt_number: 1, attempt_id: "w/1"}
    second = {attempt_number: 1, attempt_id: "w/2"}

    assert DAG::AttemptOrder.better?(second, first)
    refute DAG::AttemptOrder.better?(first, second)
  end

  def test_attempt_order_key_sorts_ascending_to_the_canonical_attempt
    attempts = [
      {attempt_number: 2, attempt_id: "w/3"},
      {attempt_number: 1, attempt_id: "w/9"},
      {attempt_number: 2, attempt_id: "w/4"}
    ]

    sorted = attempts.sort_by { |a| DAG::AttemptOrder.key(a) }
    assert_equal "w/4", sorted.last.fetch(:attempt_id)
  end

  # --- DAG::EventPublishing ----------------------------------------------

  def test_publish_quietly_forwards_to_the_bus_and_returns_nil
    seen = []
    bus = Object.new
    bus.define_singleton_method(:publish) { |event| seen << event }

    assert_nil DAG::EventPublishing.publish_quietly(bus, :event)
    assert_equal [:event], seen
  end

  def test_publish_quietly_swallows_bus_errors
    bus = Object.new
    bus.define_singleton_method(:publish) { |_event| raise "bus down" }

    assert_nil DAG::EventPublishing.publish_quietly(bus, :event)
  end

  # --- DAG::Validation optional helpers ----------------------------------

  def test_validation_optional_helpers_raise_on_wrong_type
    assert_raises(ArgumentError) { DAG::Validation.optional_hash!(1, "x") }
    assert_raises(ArgumentError) { DAG::Validation.optional_instance!(1, String, "x") }
    assert_raises(ArgumentError) { DAG::Validation.optional_node_id!(1) }
    assert_raises(ArgumentError) { DAG::Validation.dependency!(Object.new, :call, "handler") }
  end

  def test_validation_optional_node_id_accepts_nil_and_node_ids
    assert_nil DAG::Validation.optional_node_id!(nil)
    assert_equal :a, DAG::Validation.optional_node_id!(:a)
    assert_equal "a", DAG::Validation.optional_node_id!("a")
  end

  # --- DAG::Effects snapshot helpers --------------------------------------

  def test_fetch_snapshot_value_falls_back_to_default_for_opaque_snapshots
    assert_equal :fallback, DAG::Effects.fetch_snapshot_value(Object.new, :ref, :fallback)
  end

  def test_fetch_required_snapshot_value_reads_object_attributes_and_raises_when_missing
    snapshot = Struct.new(:ref).new("type:key")

    assert_equal "type:key", DAG::Effects.fetch_required_snapshot_value(snapshot, :ref)
    assert_raises(KeyError) { DAG::Effects.fetch_required_snapshot_value(Object.new, :ref) }
  end

  # --- Dispatcher value carriers ------------------------------------------

  def test_handler_result_generic_factory_builds_failed_results
    result = DAG::Effects::HandlerResult[status: :failed_terminal, error: {code: :nope}]

    assert result.failure?
    refute result.retriable?
  end

  def test_dispatch_outcome_rejects_both_succeeded_and_failed_records
    outcome_class = DAG::Effects::Dispatcher.const_get(:DispatchOutcome)
    record = nil
    error = assert_raises(ArgumentError) do
      outcome_class.new(
        succeeded_record: fake_record, failed_record: fake_record,
        released: [], error: record
      )
    end
    assert_match(/cannot contain both/, error.message)
  end

  def test_dispatcher_rejects_handlers_that_collide_after_string_coercion
    storage = DAG::Adapters::Memory::Storage.new
    handler = ->(_record) { DAG::Effects::HandlerResult.succeeded(result: {}) }

    error = assert_raises(ArgumentError) do
      DAG::Effects::Dispatcher.new(
        storage: storage,
        handlers: {"dup" => handler, :dup => handler},
        clock: FixedClock[now_ms: 1],
        owner_id: "worker",
        lease_ms: 10
      )
    end
    assert_match(/duplicate effect types/, error.message)
  end

  # --- TraceRecord / NodeDiagnostic factories ------------------------------

  def test_trace_record_keyword_factory_builds_records
    record = DAG::TraceRecord[
      workflow_id: "w",
      revision: 1,
      at_ms: 5,
      status: :retrying,
      event_type: :workflow_retrying
    ]

    assert_equal :retrying, record.status
    assert_nil record.node_id
  end

  def test_node_diagnostic_keyword_factory_and_error_code_guard
    diagnostic = DAG::NodeDiagnostic[
      workflow_id: "w",
      revision: 1,
      node_id: :a,
      state: :pending,
      terminal: false,
      attempt_count: 0
    ]
    assert_equal :a, diagnostic.node_id

    assert_raises(ArgumentError) do
      DAG::NodeDiagnostic[
        workflow_id: "w",
        revision: 1,
        node_id: :a,
        state: :pending,
        terminal: false,
        attempt_count: 0,
        last_error_code: {bad: true}
      ]
    end
  end

  # --- ExecutionContext trusted merge --------------------------------------

  def test_merge_rejects_canonical_key_collisions_across_spellings
    context = DAG::ExecutionContext.from({"a" => 1})

    error = assert_raises(ArgumentError) { context.merge({a: 2}) }
    assert_match(/canonical key collision/, error.message)
  end

  def test_merge_still_validates_and_freezes_the_patch
    context = DAG::ExecutionContext.from({"a" => 1})

    assert_raises(ArgumentError) { context.merge({"bad" => Object.new}) }

    merged = context.merge({"b" => {"nested" => [1, 2]}})
    assert_equal 1, merged["a"]
    assert merged["b"].frozen?
    assert merged["b"]["nested"].frozen?
    assert_equal({"a" => 1}, context.to_h, "merge must not mutate the receiver")
  end

  def test_merge_overwrites_same_spelling_keys_and_chains
    context = DAG::ExecutionContext.from({"a" => 1})
    merged = context.merge({"a" => 2}).merge({"c" => 3}).merge({"a" => 4})

    assert_equal 4, merged["a"]
    assert_equal 3, merged["c"]
    assert_raises(ArgumentError) { merged.merge({c: 0}) }
  end

  # --- StorageState defensive branches --------------------------------------

  def test_legacy_snapshots_rebuild_attempt_and_active_effect_indexes
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    attempt_id = begin_waiting_attempt_with_effect(storage, workflow_id, :a)

    legacy = storage.instance_variable_get(:@state).dup
    legacy.delete(:attempts_by_node)
    legacy.delete(:active_effect_order)
    revived = DAG::Adapters::Memory::Storage.new(initial_state: legacy)

    assert_equal 1, revived.count_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
    claimed = revived.claim_ready_effects(limit: 10, owner_id: "w", lease_ms: 100, now_ms: 1_000)
    assert_equal 1, claimed.size
    assert_equal attempt_id, claimed.first.attempt_id
  end

  def test_claim_skips_terminal_effects_left_in_a_corrupted_active_order
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    begin_waiting_attempt_with_effect(storage, workflow_id, :a)

    record = storage.claim_ready_effects(limit: 1, owner_id: "w", lease_ms: 100, now_ms: 1_000).first
    storage.mark_effect_succeeded(effect_id: record.id, owner_id: "w", result: {}, external_ref: nil, now_ms: 1_001)

    state = storage.instance_variable_get(:@state)
    state[:active_effect_order] << record.id

    assert_empty storage.claim_ready_effects(limit: 10, owner_id: "w", lease_ms: 100, now_ms: 2_000)
  end

  def test_commit_attempt_rejects_effect_intents_with_foreign_coordinates
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    attempt_id = storage.begin_attempt(
      workflow_id: workflow_id, revision: 1, node_id: :a,
      expected_node_state: :pending, attempt_number: 1
    )

    mismatches = {
      workflow_id: {workflow_id: "other"},
      revision: {revision: 9},
      node_id: {node_id: :zzz},
      attempt_id: {attempt_id: "other/1"}
    }
    mismatches.each do |field, override|
      intent = prepared_intent(workflow_id, attempt_id, **override)
      error = assert_raises(ArgumentError) do
        storage.commit_attempt(
          attempt_id: attempt_id,
          result: DAG::Waiting[reason: :effect_pending],
          node_state: :waiting,
          event: node_waiting_event(workflow_id, attempt_id),
          effects: [intent]
        )
      end
      assert_match(/effects\[0\]\.#{field} does not match attempt/, error.message)
    end
  end

  def test_commit_attempt_rejects_event_with_foreign_attempt_id
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    attempt_id = storage.begin_attempt(
      workflow_id: workflow_id, revision: 1, node_id: :a,
      expected_node_state: :pending, attempt_number: 1
    )

    error = assert_raises(ArgumentError) do
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: 1],
        node_state: :committed,
        event: DAG::Event[
          type: :node_committed, workflow_id: workflow_id, revision: 1,
          node_id: :a, attempt_id: "#{attempt_id}-other", at_ms: 1, payload: {}
        ]
      )
    end
    assert_match(/event\.attempt_id does not match/, error.message)
  end

  def test_append_revision_if_workflow_state_rejects_non_running_disallowed_states
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)

    error = assert_raises(DAG::StaleStateError) do
      storage.append_revision_if_workflow_state(
        id: workflow_id,
        allowed_states: %i[paused waiting],
        parent_revision: 1,
        definition: simple_definition.with_revision(2),
        invalidated_node_ids: [],
        event: nil
      )
    end
    assert_match(/cannot append revision from :pending/, error.message)
  end

  def test_committed_result_projection_carries_forward_across_two_revisions
    storage = DAG::Adapters::Memory::Storage.new
    definition = simple_definition
    workflow_id = create_workflow(storage, definition)
    commit_node(storage, workflow_id, 1, :a)

    storage.append_revision(
      id: workflow_id, parent_revision: 1, definition: definition.with_revision(2),
      invalidated_node_ids: [:b], event: nil
    )
    storage.append_revision(
      id: workflow_id, parent_revision: 2, definition: definition.with_revision(3),
      invalidated_node_ids: [:b], event: nil
    )

    results = storage.list_committed_results_for_predecessors(
      workflow_id: workflow_id, revision: 3, predecessors: [:a]
    )
    assert_equal({a: true}, results[:a].context_patch)
    assert_equal 0, storage.count_attempts(workflow_id: workflow_id, revision: 3, node_id: :a),
      "projections must not count as attempts"
  end

  # --- CrashableStorage pass-through ----------------------------------------

  def test_crashable_storage_prepare_retry_passes_through_when_trigger_does_not_match
    storage = DAG::Adapters::Memory::CrashableStorage.new(
      crash_on: {method: :prepare_workflow_retry, after: true, to: :never}
    )
    workflow_id = create_workflow(storage, simple_definition,
      runtime_profile: DAG::RuntimeProfile[
        durability: :ephemeral, max_attempts_per_node: 1,
        max_workflow_retries: 1, event_bus_kind: :null
      ])
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
    storage.transition_workflow_state(id: workflow_id, from: :running, to: :failed)

    row = storage.prepare_workflow_retry(id: workflow_id)
    assert_equal :pending, row[:state]
  end

  private

  def fake_record
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    attempt_id = begin_waiting_attempt_with_effect(storage, workflow_id, :a)
    storage.list_effects_for_attempt(attempt_id: attempt_id).first
  end

  def begin_waiting_attempt_with_effect(storage, workflow_id, node_id)
    attempt_id = storage.begin_attempt(
      workflow_id: workflow_id, revision: 1, node_id: node_id,
      expected_node_state: :pending, attempt_number: 1
    )
    storage.commit_attempt(
      attempt_id: attempt_id,
      result: DAG::Waiting[reason: :effect_pending],
      node_state: :waiting,
      event: node_waiting_event(workflow_id, attempt_id, node_id: node_id),
      effects: [prepared_intent(workflow_id, attempt_id, node_id: node_id)]
    )
    attempt_id
  end

  def prepared_intent(workflow_id, attempt_id, **overrides)
    DAG::Effects::PreparedIntent[
      workflow_id: workflow_id,
      revision: 1,
      node_id: :a,
      attempt_id: attempt_id,
      type: "external.call",
      key: "k-#{attempt_id}",
      payload: {n: 1},
      payload_fingerprint: "fp-1",
      blocking: true,
      created_at_ms: 1_000,
      **overrides
    ]
  end

  def node_waiting_event(workflow_id, attempt_id, node_id: :a)
    DAG::Event[
      type: :node_waiting,
      workflow_id: workflow_id,
      revision: 1,
      node_id: node_id,
      attempt_id: attempt_id,
      at_ms: 1_000,
      payload: {}
    ]
  end
end
