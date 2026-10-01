# frozen_string_literal: true

require_relative "../test_helper"

class WaitingEffectMutationTest < Minitest::Test
  def test_unrelated_mutation_keeps_waiting_effect_releasable
    storage = DAG::Adapters::Memory::Storage.new
    intent = DAG::Effects::Intent[type: "check", key: "one", payload: {value: 1}]
    inputs = []
    step = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        inputs << input
        DAG::Effects::Await.call(input, intent) do |result|
          DAG::Success[value: result, context_patch: {checked: true}]
        end
      end
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :await_check, klass: step, fingerprint_payload: {v: 1})
    registry.register(name: :noop, klass: DAG::BuiltinSteps::Noop, fingerprint_payload: {v: 1})
    registry.freeze!
    runner = build_runner(storage: storage, registry: registry)
    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :await_check)
      .add_node(:b, type: :noop)
    workflow_id = create_workflow(storage, definition)

    assert_equal :waiting, runner.call(workflow_id).state
    effect = storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a).first
    service = DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Memory::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )
    service.apply(
      workflow_id: workflow_id,
      mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :b],
      expected_revision: 1
    )
    assert_empty storage.list_attempts(workflow_id: workflow_id, revision: 2, node_id: :a)

    storage.claim_ready_effects(limit: 1, owner_id: "worker", lease_ms: 500, now_ms: 1_000)
    completion = storage.complete_effect_succeeded(
      effect_id: effect.id,
      owner_id: "worker",
      result: {value: 1},
      external_ref: "check-1",
      now_ms: 1_100
    )

    assert_equal [2], completion[:released].map { |entry| entry[:revision] }
    assert_equal :completed, runner.resume(workflow_id).state
    assert_equal 2, inputs.size
    assert_equal :succeeded, inputs.last.metadata[:effects][intent.ref][:status]
    assert_equal 1, storage.list_attempts(workflow_id: workflow_id, revision: 2, node_id: :a).size
  end
end
