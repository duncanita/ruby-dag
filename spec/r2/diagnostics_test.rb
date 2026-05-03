# frozen_string_literal: true

require_relative "../test_helper"

class DiagnosticsTest < Minitest::Test
  FixedClock = Data.define(:now_ms) do
    def now = Time.at(now_ms / 1000.0)
    def monotonic_ms = now_ms
  end

  def test_trace_records_are_deterministic_json_safe_values_from_durable_events
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :passthrough))

    build_runner(storage: storage, clock: FixedClock.new(now_ms: 1_234)).call(workflow_id)

    records = DAG::Diagnostics.trace_records(storage: storage, workflow_id: workflow_id)

    assert records.all? { |record| record.is_a?(DAG::TraceRecord) }
    assert records.all?(&:frozen?)
    assert_equal [1, 2, 3, 4], records.map(&:seq)
    assert_equal %i[workflow_started node_started node_committed workflow_completed], records.map(&:event_type)
    assert_equal %i[started started success completed], records.map(&:status)

    committed = records.fetch(2)
    assert_equal workflow_id, committed.workflow_id
    assert_equal 1, committed.revision
    assert_equal :a, committed.node_id
    assert_match %r{\A#{Regexp.escape(workflow_id)}/1\z}, committed.attempt_id
    assert_equal 1_234, committed.at_ms
    assert_equal({attempt_number: 1}, committed.payload)
    assert committed.payload.frozen?
    records.each { |record| DAG.json_safe!(record.to_h) }
    assert_equal committed.to_h, DAG::TraceRecord.from_event(storage.read_events(workflow_id: workflow_id).fetch(2)).to_h
  end

  def test_trace_record_status_mapping_covers_closed_event_type_set
    assert_equal DAG::Event::TYPES.sort, DAG::TraceRecord::EVENT_STATUS.keys.sort
    assert_equal [], DAG::TraceRecord::EVENT_STATUS.values - DAG::TraceRecord::STATUSES
  end

  def test_node_diagnostics_describe_successful_nodes
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :passthrough))

    build_runner(storage: storage, clock: FixedClock.new(now_ms: 2_000)).call(workflow_id)

    diagnostic = diagnostic_for(storage, workflow_id, :a)

    assert_instance_of DAG::NodeDiagnostic, diagnostic
    assert diagnostic.frozen?
    assert_equal workflow_id, diagnostic.workflow_id
    assert_equal 1, diagnostic.revision
    assert_equal :a, diagnostic.node_id
    assert_equal :committed, diagnostic.state
    assert diagnostic.terminal
    assert_equal 1, diagnostic.attempt_count
    assert_match %r{\A#{Regexp.escape(workflow_id)}/1\z}, diagnostic.last_attempt_id
    assert_nil diagnostic.last_error_code
    assert_nil diagnostic.last_error_attempt_id
    assert_nil diagnostic.waiting_reason
    assert_equal [], diagnostic.effect_refs
    assert_equal({}, diagnostic.effect_statuses)
    assert_nil diagnostic.effects_terminal
    assert diagnostic.to_h.frozen?
    DAG.json_safe!(diagnostic.to_h)
  end

  def test_node_diagnostics_describe_waiting_nodes_with_pending_effects
    storage = DAG::Adapters::Memory::Storage.new
    intent = effect_intent(key: "approval")
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :await_effect))

    build_runner(
      storage: storage,
      registry: registry_with_effect_await_step(intent: intent),
      clock: FixedClock.new(now_ms: 3_000)
    ).call(workflow_id)

    diagnostic = diagnostic_for(storage, workflow_id, :a)

    assert_equal :waiting, diagnostic.state
    refute diagnostic.terminal
    assert_equal 1, diagnostic.attempt_count
    assert_equal :effect_pending, diagnostic.waiting_reason
    assert_nil diagnostic.last_error_code
    assert_equal [intent.ref], diagnostic.effect_refs
    assert_equal({intent.ref => :reserved}, diagnostic.effect_statuses)
    assert_equal false, diagnostic.effects_terminal
  end

  def test_node_diagnostics_describe_terminal_effects_before_rerun
    storage = DAG::Adapters::Memory::Storage.new
    intent = effect_intent(key: "done")
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :await_effect))
    runner = build_runner(
      storage: storage,
      registry: registry_with_effect_await_step(intent: intent),
      clock: FixedClock.new(now_ms: 4_000)
    )

    runner.call(workflow_id)
    effect = storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a).fetch(0)
    mark_effect_succeeded_and_release(storage, effect.id, result: {value: "ok"})

    diagnostic = diagnostic_for(storage, workflow_id, :a)

    assert_equal :pending, diagnostic.state
    refute diagnostic.terminal
    assert_nil diagnostic.waiting_reason
    assert_equal [intent.ref], diagnostic.effect_refs
    assert_equal({intent.ref => :succeeded}, diagnostic.effect_statuses)
    assert_equal true, diagnostic.effects_terminal
  end

  def test_node_diagnostics_attribute_terminal_failures_to_node_and_attempt
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :always_fails))

    build_runner(
      storage: storage,
      registry: registry_with_terminal_failure_step(code: :hard_fail),
      clock: FixedClock.new(now_ms: 5_000)
    ).call(workflow_id)

    diagnostic = diagnostic_for(storage, workflow_id, :a)

    assert_equal :failed, diagnostic.state
    assert diagnostic.terminal
    assert_equal 1, diagnostic.attempt_count
    assert_match %r{\A#{Regexp.escape(workflow_id)}/1\z}, diagnostic.last_attempt_id
    assert_equal diagnostic.last_attempt_id, diagnostic.last_error_attempt_id
    assert_equal :hard_fail, diagnostic.last_error_code
    assert_nil diagnostic.waiting_reason
  end

  def test_node_diagnostics_preserve_numeric_string_keyed_error_codes
    diagnostic = DAG::NodeDiagnostic.from_records(
      workflow_id: "wf",
      revision: 1,
      node_id: :a,
      state: :failed,
      attempts: [failure_attempt("wf/1", error: {"code" => 404})]
    )

    assert_equal 404, diagnostic.last_error_code
    assert_equal "wf/1", diagnostic.last_error_attempt_id
    DAG.json_safe!(diagnostic.to_h)
  end

  def test_node_diagnostics_ignore_json_safe_failures_without_error_codes
    diagnostic = DAG::NodeDiagnostic.from_records(
      workflow_id: "wf",
      revision: 1,
      node_id: :a,
      state: :failed,
      attempts: [failure_attempt("wf/1", error: ["boom"])]
    )

    assert_nil diagnostic.last_error_code
    assert_equal "wf/1", diagnostic.last_error_attempt_id
    DAG.json_safe!(diagnostic.to_h)
  end

  private

  def diagnostic_for(storage, workflow_id, node_id)
    DAG::Diagnostics.node_diagnostics(storage: storage, workflow_id: workflow_id).find { |d| d.node_id == node_id }
  end

  def effect_intent(key:, payload: {value: 1})
    DAG::Effects::Intent[type: "test", key: key, payload: payload, metadata: {source: "diagnostics-spec"}]
  end

  def failure_attempt(attempt_id, error:)
    {
      attempt_id: attempt_id,
      attempt_number: 1,
      result: DAG::Failure[error: error, retriable: false]
    }
  end

  def registry_with_effect_await_step(intent:)
    registry = DAG::StepTypeRegistry.new
    klass = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        DAG::Effects::Await.call(input, intent) do |effect_result|
          DAG::Success[value: effect_result, context_patch: {}]
        end
      end
    end
    registry.register(name: :await_effect, klass: klass, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end

  def registry_with_terminal_failure_step(code:)
    registry = DAG::StepTypeRegistry.new
    klass = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        DAG::Failure[error: {code: code, message: "failed"}, retriable: false]
      end
    end
    registry.register(name: :always_fails, klass: klass, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end

  def mark_effect_succeeded_and_release(storage, effect_id, result:)
    claimed = storage.claim_ready_effects(limit: 1, owner_id: "worker", lease_ms: 500, now_ms: 1_000)
    assert_equal [effect_id], claimed.map(&:id)
    storage.mark_effect_succeeded(
      effect_id: effect_id,
      owner_id: "worker",
      result: result,
      external_ref: "external-#{effect_id}",
      now_ms: 1_100
    )
    storage.release_nodes_satisfied_by_effect(effect_id: effect_id, now_ms: 1_200)
  end
end
