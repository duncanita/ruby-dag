# frozen_string_literal: true

require_relative "../test_helper"

class RunnerEffectsTest < Minitest::Test
  def test_waiting_with_proposed_effect_reserves_record_and_waiting_event_payload
    storage = DAG::Adapters::Memory::Storage.new
    intent = effect_intent(key: "approval")
    registry = registry_with_effect_await_step(intent: intent)
    runner = build_runner(storage: storage, registry: registry)
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :await_effect))

    result = runner.call(workflow_id)

    assert_equal :waiting, result.state
    assert_equal :waiting, node_state(storage, workflow_id, :a)

    records = storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a)
    assert_equal 1, records.size
    assert_equal intent.ref, records.first.ref
    assert_equal fingerprint.compute(intent.payload), records.first.payload_fingerprint
    assert records.first.blocking

    waiting_event = storage.read_events(workflow_id: workflow_id).find { |event| event.type == :node_waiting }
    assert_equal [intent.ref], waiting_event.payload[:effect_refs]
    assert_equal 1, waiting_event.payload[:effect_count]
  end

  def test_resume_before_terminal_effect_does_not_rerun_waiting_node
    storage = DAG::Adapters::Memory::Storage.new
    intent = effect_intent(key: "slow")
    calls = []
    registry = registry_with_effect_await_step(intent: intent, calls: calls)
    runner = build_runner(storage: storage, registry: registry)
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :await_effect))

    runner.call(workflow_id)
    result = runner.resume(workflow_id)

    assert_equal :waiting, result.state
    assert_equal 1, calls.size
    assert_equal :waiting, node_state(storage, workflow_id, :a)
  end

  def test_resume_after_effect_success_reruns_node_with_effect_snapshot
    storage = DAG::Adapters::Memory::Storage.new
    intent = effect_intent(key: "done")
    calls = []
    registry = registry_with_effect_await_step(intent: intent, calls: calls)
    runner = build_runner(storage: storage, registry: registry)
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :await_effect))

    runner.call(workflow_id)
    effect = storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a).first
    mark_effect_succeeded_and_release(storage, effect.id, result: {value: "ok"})

    result = runner.resume(workflow_id)

    assert_equal :completed, result.state
    assert_equal 2, calls.size
    second_input = calls.last
    snapshot = second_input.metadata[:effects][intent.ref]
    assert_equal :succeeded, snapshot[:status]
    assert_equal({value: "ok"}, snapshot[:result])
    assert snapshot.frozen?

    attempt = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).last
    assert_equal :committed, attempt[:state]
    assert_equal({effect_value: "ok"}, attempt[:result].context_patch)
  end

  def test_step_sees_only_effects_for_its_own_node
    storage = DAG::Adapters::Memory::Storage.new
    intent = effect_intent(key: "node-a")
    observed_b_effects = []
    registry = DAG::StepTypeRegistry.new
    wait_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        DAG::Waiting[reason: :effect_pending, proposed_effects: [intent]]
      end
    end
    capture_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        observed_b_effects << input.metadata.fetch(:effects)
        DAG::Success[value: :b, context_patch: {}]
      end
    end
    registry.register(name: :wait_a, klass: wait_class, fingerprint_payload: {v: 1})
    registry.register(name: :capture_b, klass: capture_class, fingerprint_payload: {v: 1})
    registry.freeze!
    runner = build_runner(storage: storage, registry: registry)
    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :wait_a)
      .add_node(:b, type: :capture_b)
    workflow_id = create_workflow(storage, definition)

    result = runner.call(workflow_id)

    assert_equal :waiting, result.state
    assert_equal [{}], observed_b_effects
    assert_equal 1, storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a).size
    assert_empty storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :b)
  end

  def test_success_with_proposed_effect_records_detached_effect_and_commits_node
    storage = DAG::Adapters::Memory::Storage.new
    intent = effect_intent(key: "detached", payload: {task: "notify"})
    registry = DAG::StepTypeRegistry.new
    success_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        DAG::Success[value: :ok, context_patch: {ok: true}, proposed_effects: [intent]]
      end
    end
    registry.register(name: :success_effect, klass: success_class, fingerprint_payload: {v: 1})
    registry.freeze!
    runner = build_runner(storage: storage, registry: registry)
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :success_effect))

    result = runner.call(workflow_id)

    assert_equal :completed, result.state
    assert_equal :committed, node_state(storage, workflow_id, :a)
    attempt = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).first
    records = storage.list_effects_for_attempt(attempt_id: attempt[:attempt_id])
    assert_equal 1, records.size
    assert_equal intent.ref, records.first.ref
    refute records.first.blocking
    assert_equal :reserved, records.first.status
  end

  def test_non_effect_workflow_still_gets_empty_effect_snapshot
    storage = DAG::Adapters::Memory::Storage.new
    observed_effects = []
    registry = DAG::StepTypeRegistry.new
    klass = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        observed_effects << input.metadata.fetch(:effects)
        DAG::Success[value: :ok, context_patch: {}]
      end
    end
    registry.register(name: :plain, klass: klass, fingerprint_payload: {v: 1})
    registry.freeze!
    runner = build_runner(storage: storage, registry: registry)
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :plain))

    result = runner.call(workflow_id)

    assert_equal :completed, result.state
    assert_equal [{}], observed_effects
  end

  private

  def effect_intent(key:, payload: {value: 1})
    DAG::Effects::Intent[type: "test", key: key, payload: payload, metadata: {source: "spec"}]
  end

  def registry_with_effect_await_step(intent:, calls: [])
    registry = DAG::StepTypeRegistry.new
    klass = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        calls << input
        DAG::Effects::Await.call(input, intent) do |effect_result|
          DAG::Success[
            value: effect_result,
            context_patch: {effect_value: effect_result.fetch(:value)}
          ]
        end
      end
    end
    registry.register(name: :await_effect, klass: klass, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end

  def fingerprint
    @fingerprint ||= DAG::Adapters::Stdlib::Fingerprint.new
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
