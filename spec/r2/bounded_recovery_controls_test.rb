# frozen_string_literal: true

require_relative "../test_helper"

class R2BoundedRecoveryControlsTest < Minitest::Test
  def test_retry_exhaustion_and_duplicate_prepare_are_storage_boundaries
    storage = DAG::Adapters::Memory::Storage.new
    registry, _counter = registry_with_failing_step(failures_before_success: 100)
    runner = build_runner(storage: storage, registry: registry)
    definition = DAG::Workflow::Definition.new.add_node(:flaky, type: :flaky)
    workflow_id = create_workflow(storage, definition,
      runtime_profile: retry_profile(max_attempts_per_node: 1, max_workflow_retries: 1))

    assert_equal :failed, runner.call(workflow_id).state

    receipt = storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)
    assert_equal({id: workflow_id, state: :pending, reset: [:flaky], workflow_retry_count: 1, event: nil}, receipt)

    assert_raises(DAG::StaleStateError) do
      storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)
    end
    assert_equal :pending, storage.load_workflow(id: workflow_id)[:state]
    assert_equal 1, storage.load_workflow(id: workflow_id)[:workflow_retry_count]

    assert_equal :failed, runner.call(workflow_id).state
    assert_raises(DAG::WorkflowRetryExhaustedError) do
      storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)
    end
    assert_equal :failed, storage.load_workflow(id: workflow_id)[:state]
    assert_equal 1, storage.load_workflow(id: workflow_id)[:workflow_retry_count]
  end

  def test_resume_from_running_aborts_orphan_attempt_and_reinvokes_once
    storage = DAG::Adapters::Memory::Storage.new
    call_log = []
    registry = registry_with_logging_step(call_log)
    workflow_id = create_workflow(storage, single_logging_definition)

    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
    stale_attempt_id = storage.begin_attempt(
      workflow_id: workflow_id,
      revision: 1,
      node_id: :a,
      expected_node_state: :pending,
      attempt_number: 1
    )

    result = build_runner(storage: storage, registry: registry).resume(workflow_id)

    assert_equal :completed, result.state
    assert_equal [:a], call_log
    attempts = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
    assert_equal 2, attempts.length
    assert_equal stale_attempt_id, attempts.first[:attempt_id]
    assert attempts.last[:attempt_id]
    refute_equal stale_attempt_id, attempts.last[:attempt_id]
    assert_equal [:aborted, :committed], attempts.map { |attempt| attempt[:state] }
    assert_equal [1, 1], attempts.map { |attempt| attempt[:attempt_number] }
  end

  def test_resume_from_waiting_is_idempotent_until_consumer_releases_state
    storage = DAG::Adapters::Memory::Storage.new
    call_count = 0
    registry = waiting_registry { call_count += 1 }
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :wait))
    runner = build_runner(storage: storage, registry: registry)

    assert_equal :waiting, runner.call(workflow_id).state
    3.times { assert_equal :waiting, build_runner(storage: storage, registry: registry).resume(workflow_id).state }

    assert_equal 1, call_count
    assert_equal :waiting, node_state(storage, workflow_id, :a)
  end

  def test_resume_from_paused_completes_without_replaying_mutation_proposal
    storage = DAG::Adapters::Memory::Storage.new
    call_count = 0
    registry = pausing_registry { call_count += 1 }
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :pause))
    runner = build_runner(storage: storage, registry: registry)

    assert_equal :paused, runner.call(workflow_id).state
    assert_equal :completed, build_runner(storage: storage, registry: registry).resume(workflow_id).state

    assert_equal 1, call_count
    assert_equal :committed, node_state(storage, workflow_id, :a)
  end

  def test_mutation_apply_rejects_running_and_race_to_running
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
    service = mutation_service(storage)

    assert_raises(DAG::ConcurrentMutationError) do
      service.apply(
        workflow_id: workflow_id,
        mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :a],
        expected_revision: 1
      )
    end

    paused_storage = DAG::Adapters::Memory::Storage.new
    paused_workflow_id = create_workflow(paused_storage, simple_definition)
    paused_storage.transition_workflow_state(id: paused_workflow_id, from: :pending, to: :paused)
    racing_storage = StateRacingStorage.new(paused_storage, workflow_id: paused_workflow_id, from: :paused, to: :running)

    assert_raises(DAG::ConcurrentMutationError) do
      mutation_service(racing_storage).apply(
        workflow_id: paused_workflow_id,
        mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :a],
        expected_revision: 1
      )
    end
    assert_equal 1, paused_storage.load_current_definition(id: paused_workflow_id).revision
  end

  def test_mutation_metadata_is_transport_not_planner_or_verifier_policy
    editor = DAG::DefinitionEditor.new
    first = policy_shaped_mutation(rationale: "prefer smaller plan", confidence: 0.3, metadata: {review: "manual"})
    second = policy_shaped_mutation(rationale: "prefer safer plan", confidence: 0.9, metadata: {review: "automated"})

    first_plan = editor.plan(simple_definition, first)
    second_plan = editor.plan(simple_definition, second)

    assert first_plan.valid?
    assert second_plan.valid?
    assert_equal first_plan.invalidated_node_ids, second_plan.invalidated_node_ids
    assert_equal first_plan.new_definition.to_h, second_plan.new_definition.to_h
  end

  def test_contract_states_that_escalation_policy_belongs_to_consumers
    contract = File.read(File.expand_path("../../CONTRACT.md", __dir__)).gsub(/\s+/, " ")

    assert_includes contract,
      "Retry exhaustion, waiting, and paused states are bounded kernel outcomes; consumers own escalation policy, alerting, approval, backoff, and replacement workflows."
  end

  private

  def retry_profile(max_attempts_per_node:, max_workflow_retries:)
    DAG::RuntimeProfile[
      durability: :ephemeral,
      max_attempts_per_node: max_attempts_per_node,
      max_workflow_retries: max_workflow_retries,
      event_bus_kind: :null
    ]
  end

  def single_logging_definition
    DAG::Workflow::Definition.new.add_node(:a, type: :logging)
  end

  def waiting_registry(&block)
    wait_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        block.call
        DAG::Waiting[reason: :external]
      end
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :wait, klass: wait_class, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end

  def pausing_registry(&block)
    pause_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        block.call
        DAG::Success[
          value: :paused,
          proposed_mutations: [DAG::ProposedMutation[kind: :invalidate, target_node_id: :a]]
        ]
      end
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :pause, klass: pause_class, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end

  def mutation_service(storage)
    DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Null::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )
  end

  def policy_shaped_mutation(rationale:, confidence:, metadata:)
    DAG::ProposedMutation[
      kind: :invalidate,
      target_node_id: :a,
      rationale: rationale,
      confidence: confidence,
      metadata: metadata
    ]
  end

  class StateRacingStorage
    def initialize(storage, workflow_id:, from:, to:)
      @storage = storage
      @workflow_id = workflow_id
      @from = from
      @to = to
      @raced = false
    end

    def append_revision_if_workflow_state(**kwargs)
      unless @raced
        @raced = true
        @storage.transition_workflow_state(id: @workflow_id, from: @from, to: @to)
      end
      @storage.append_revision_if_workflow_state(**kwargs)
    end

    def method_missing(name, ...)
      @storage.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @storage.respond_to?(name, include_private) || super
    end
  end
end
