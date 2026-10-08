# frozen_string_literal: true

require_relative "../test_helper"

class WorkflowRunClaimTest < Minitest::Test
  class Clock
    attr_accessor :time_ms

    def initialize(time_ms = 1_000)
      @time_ms = time_ms
    end

    def now_ms = time_ms
  end

  def setup
    @clock = Clock.new
    @storage = DAG::Adapters::Memory::Storage.new(clock: @clock)
    @definition = DAG::Workflow::Definition.new.add_node(:a, type: :noop)
    @workflow_id = create_workflow(@storage, @definition)
  end

  def test_claim_expiry_takeover_and_stale_renewal
    first = @storage.claim_workflow_run(id: @workflow_id, owner_id: "a", lease_ms: 100)
    assert_equal 1, first.fencing_token
    assert first.frozen?
    assert_raises(DAG::StaleRunClaimError) do
      @storage.claim_workflow_run(id: @workflow_id, owner_id: "b", lease_ms: 100)
    end

    @clock.time_ms = 1_100
    second = @storage.claim_workflow_run(id: @workflow_id, owner_id: "b", lease_ms: 100)
    assert_equal 2, second.fencing_token
    assert_raises(DAG::StaleRunClaimError) { @storage.renew_workflow_run(claim: first, until_ms: 1_300) }
    assert_equal 1_300, @storage.renew_workflow_run(claim: second, until_ms: 1_300).lease_until_ms
    assert_equal true, @storage.release_workflow_run(claim: second)
    assert_raises(DAG::StaleRunClaimError) { @storage.renew_workflow_run(claim: second, until_ms: 1_400) }
  end

  def test_unissued_claim_cannot_opt_into_fencing
    forged = DAG::WorkflowRunClaim[workflow_id: @workflow_id, owner_id: "a",
      fencing_token: 1, lease_until_ms: 2_000]
    assert_raises(DAG::StaleRunClaimError) do
      @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :running, claim: forged)
    end
    assert_equal :pending, @storage.load_workflow(id: @workflow_id)[:state]
  end

  def test_claimed_workflow_rejects_legacy_and_stale_writes
    first = @storage.claim_workflow_run(id: @workflow_id, owner_id: "a", lease_ms: 100)
    assert_raises(DAG::StaleRunClaimError) do
      @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :running)
    end
    @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :running, claim: first)
    @clock.time_ms = 1_100
    second = @storage.claim_workflow_run(id: @workflow_id, owner_id: "b", lease_ms: 100)
    assert_raises(DAG::StaleRunClaimError) do
      @storage.begin_attempt(workflow_id: @workflow_id, revision: 1, node_id: :a,
        expected_node_state: :pending, attempt_number: 1, claim: first)
    end
    assert_empty @storage.list_attempts(workflow_id: @workflow_id)
    assert_equal :running, @storage.load_workflow(id: @workflow_id)[:state]
    assert_equal 1, @storage.begin_attempt(workflow_id: @workflow_id, revision: 1, node_id: :a,
      expected_node_state: :pending, attempt_number: 1, claim: second).split("/").last.to_i
  end

  def test_runner_resume_with_takeover_completes_once
    first = @storage.claim_workflow_run(id: @workflow_id, owner_id: "a", lease_ms: 100)
    runner_a = build_runner(storage: @storage)
    runner_b = build_runner(storage: @storage)
    @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :running, claim: first)
    abandoned_attempt = @storage.begin_attempt(workflow_id: @workflow_id, revision: 1, node_id: :a,
      expected_node_state: :pending, attempt_number: 1, claim: first)
    @clock.time_ms = 1_100
    second = @storage.claim_workflow_run(id: @workflow_id, owner_id: "b", lease_ms: 1_000)

    assert_raises(DAG::StaleRunClaimError) { runner_a.resume(@workflow_id, claim: first) }
    assert_equal :completed, runner_b.resume(@workflow_id, claim: second).state
    assert_equal :aborted, @storage.list_attempts(workflow_id: @workflow_id).find { |attempt| attempt[:attempt_id] == abandoned_attempt }[:state]
    assert_equal 1, @storage.list_attempts(workflow_id: @workflow_id).count { |attempt| attempt[:state] == :committed }
    assert_equal 1, @storage.read_events(workflow_id: @workflow_id).count { |event| event.type == :workflow_completed }
  end

  def test_stale_claim_cannot_abort_transition_node_or_append_revision
    first = @storage.claim_workflow_run(id: @workflow_id, owner_id: "a", lease_ms: 100)
    @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :running, claim: first)
    attempt_id = @storage.begin_attempt(workflow_id: @workflow_id, revision: 1, node_id: :a,
      expected_node_state: :pending, attempt_number: 1, claim: first)
    @clock.time_ms = 1_100
    second = @storage.claim_workflow_run(id: @workflow_id, owner_id: "b", lease_ms: 100)

    assert_raises(DAG::StaleRunClaimError) { @storage.abort_running_attempts(workflow_id: @workflow_id, claim: first) }
    assert_raises(DAG::StaleRunClaimError) do
      @storage.transition_node_state(workflow_id: @workflow_id, revision: 1, node_id: :a,
        from: :running, to: :pending, claim: first)
    end
    assert_raises(DAG::StaleRunClaimError) do
      @storage.append_revision(id: @workflow_id, parent_revision: 1, definition: @definition,
        invalidated_node_ids: [], event: nil, claim: first)
    end
    assert_raises(DAG::StaleRunClaimError) do
      @storage.append_revision_if_workflow_state(id: @workflow_id, allowed_states: [:running],
        parent_revision: 1, definition: @definition, invalidated_node_ids: [], event: nil, claim: first)
    end
    assert_equal :running, @storage.list_attempts(workflow_id: @workflow_id).first[:state]
    assert_equal 1, @storage.load_workflow(id: @workflow_id)[:current_revision]
    assert_equal [attempt_id], @storage.abort_running_attempts(workflow_id: @workflow_id, claim: second)
  end

  def test_expired_claim_cannot_write_even_without_takeover
    claim = @storage.claim_workflow_run(id: @workflow_id, owner_id: "a", lease_ms: 100)
    @clock.time_ms = 1_100

    assert_raises(DAG::StaleRunClaimError) do
      @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :running, claim: claim)
    end
    assert_equal :pending, @storage.load_workflow(id: @workflow_id)[:state]
    assert_raises(DAG::StaleRunClaimError) { @storage.release_workflow_run(claim: claim) }
  end

  def test_takeover_during_step_fences_late_commit_and_effect_reservation
    calls = 0
    takeover_claim = nil
    storage = @storage
    clock = @clock
    intent = DAG::Effects::Intent[type: "check", key: "k", payload: {}]
    step = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        calls += 1
        if calls == 1
          clock.time_ms = 1_100
          takeover_claim = storage.claim_workflow_run(id: "wf", owner_id: "b", lease_ms: 1_000)
        end
        DAG::Success[value: calls, proposed_effects: [intent]]
      end
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :takeover, klass: step, fingerprint_payload: {v: 1})
    registry.freeze!
    workflow_id = "wf"
    @storage.create_workflow(id: workflow_id,
      initial_definition: DAG::Workflow::Definition.new.add_node(:a, type: :takeover),
      initial_context: {}, runtime_profile: DAG::RuntimeProfile[
        durability: :durable, max_attempts_per_node: 1, max_workflow_retries: 0,
        event_bus_kind: :null, metadata: {}
      ])
    first = @storage.claim_workflow_run(id: workflow_id, owner_id: "a", lease_ms: 100)
    runner_a = build_runner(storage: @storage, registry: registry)
    runner_b = build_runner(storage: @storage, registry: registry)

    assert_raises(DAG::StaleRunClaimError) { runner_a.call(workflow_id, claim: first) }
    assert_equal :running, @storage.list_attempts(workflow_id: workflow_id).first[:state]
    assert_empty @storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a)
    assert_equal :completed, runner_b.resume(workflow_id, claim: takeover_claim).state
    assert_equal %i[aborted committed], @storage.list_attempts(workflow_id: workflow_id).map { |attempt| attempt[:state] }
    assert_equal 1, @storage.read_events(workflow_id: workflow_id).count { |event| event.type == :workflow_completed }
    assert_equal 1, @storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a).size
    effect = @storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a).first
    diagnostic = DAG::Event[type: :effect_dispatch_stale_lease, workflow_id: workflow_id,
      revision: 1, node_id: :a, attempt_id: effect.attempt_id,
      at_ms: @clock.now_ms, payload: {effect_id: effect.id}]
    assert_raises(DAG::StaleRunClaimError) do
      @storage.append_event(workflow_id: workflow_id, event: diagnostic, claim: first)
    end
    stamped = @storage.append_effect_stale_lease_event(effect_id: effect.id, event: diagnostic)
    assert_equal :effect_dispatch_stale_lease, stamped.type
    assert_raises(ArgumentError) do
      @storage.append_effect_stale_lease_event(effect_id: effect.id, event: diagnostic.with(type: :workflow_started))
    end
  end

  def test_mutation_service_requires_claim_after_claim_mode_begins
    claim = @storage.claim_workflow_run(id: @workflow_id, owner_id: "a", lease_ms: 100)
    @storage.transition_workflow_state(id: @workflow_id, from: :pending, to: :waiting, claim: claim)
    service = DAG::MutationService.new(storage: @storage,
      event_bus: DAG::Adapters::Null::EventBus.new, clock: @clock)
    mutation = DAG::ProposedMutation[kind: :invalidate, target_node_id: :a]

    assert_raises(DAG::StaleRunClaimError) do
      service.apply(workflow_id: @workflow_id, mutation: mutation, expected_revision: 1)
    end
    assert_equal 1, @storage.load_workflow(id: @workflow_id)[:current_revision]
    assert_equal 2, service.apply(workflow_id: @workflow_id, mutation: mutation,
      expected_revision: 1, claim: claim).revision
  end

  def test_retry_requires_current_claim
    profile = DAG::RuntimeProfile[
      durability: :durable, max_attempts_per_node: 1,
      max_workflow_retries: 1, event_bus_kind: :null, metadata: {}
    ]
    workflow_id = create_workflow(@storage, @definition, runtime_profile: profile)
    first = @storage.claim_workflow_run(id: workflow_id, owner_id: "a", lease_ms: 100)
    @storage.transition_workflow_state(id: workflow_id, from: :pending, to: :failed, claim: first)
    @clock.time_ms = 1_100
    second = @storage.claim_workflow_run(id: workflow_id, owner_id: "b", lease_ms: 1_000)
    runner = build_runner(storage: @storage)

    assert_raises(DAG::StaleRunClaimError) { runner.retry_workflow(workflow_id, claim: first) }
    assert_equal 0, @storage.load_workflow(id: workflow_id)[:workflow_retry_count]
    assert_equal :completed, runner.retry_workflow(workflow_id, claim: second).state
    assert_equal 1, @storage.read_events(workflow_id: workflow_id).count { |event| event.type == :workflow_retrying }
  end
end
