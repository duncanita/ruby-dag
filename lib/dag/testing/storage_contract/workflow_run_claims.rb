# frozen_string_literal: true

module DAG::Testing::StorageContract
  module WorkflowRunClaims
    def test_contract_run_claim_takeover_and_expired_owner_rejected
      clock = Struct.new(:now_ms).new(1_000)
      storage = build_contract_storage(clock: clock)
      workflow_id = contract_create_workflow(storage)
      first = storage.claim_workflow_run(id: workflow_id, owner_id: "first", lease_ms: 100)

      assert_equal 1, first.fencing_token
      assert_raises(DAG::StaleRunClaimError) do
        storage.claim_workflow_run(id: workflow_id, owner_id: "second", lease_ms: 100)
      end
      clock.now_ms = 1_100
      second = storage.claim_workflow_run(id: workflow_id, owner_id: "second", lease_ms: 100)
      assert_operator second.fencing_token, :>, first.fencing_token
      assert_raises(DAG::StaleRunClaimError) { storage.renew_workflow_run(claim: first, until_ms: 1_300) }
      assert_equal :pending, storage.load_workflow(id: workflow_id)[:state]
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running, claim: second)
      assert_raises(DAG::StaleRunClaimError) do
        storage.transition_workflow_state(id: workflow_id, from: :running, to: :failed, claim: first)
      end
      assert_equal :running, storage.load_workflow(id: workflow_id)[:state]
    end

    def test_contract_claimed_run_fences_attempt_commit_and_event_atomically
      clock = Struct.new(:now_ms).new(1_000)
      storage = build_contract_storage(clock: clock)
      workflow_id = contract_create_workflow(storage)
      first = storage.claim_workflow_run(id: workflow_id, owner_id: "first", lease_ms: 100)
      attempt_id = storage.begin_attempt(workflow_id: workflow_id, revision: 1, node_id: :a,
        expected_node_state: :pending, attempt_number: 1, claim: first)
      clock.now_ms = 1_100
      second = storage.claim_workflow_run(id: workflow_id, owner_id: "second", lease_ms: 100)
      event = contract_event(workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
      before_events = storage.read_events(workflow_id: workflow_id)

      assert_raises(DAG::StaleRunClaimError) do
        storage.commit_attempt(attempt_id: attempt_id, result: DAG::Success[value: 1],
          node_state: :committed, event: event, claim: first)
      end
      assert_equal :running, storage.list_attempts(workflow_id: workflow_id).first[:state]
      assert_equal before_events, storage.read_events(workflow_id: workflow_id)
      assert_raises(DAG::StaleRunClaimError) do
        storage.append_event(workflow_id: workflow_id, event: contract_event(type: :workflow_started, workflow_id: workflow_id))
      end
      assert_equal before_events, storage.read_events(workflow_id: workflow_id)
      storage.commit_attempt(attempt_id: attempt_id, result: DAG::Success[value: 1],
        node_state: :committed, event: event, claim: second)
      assert_equal :committed, storage.list_attempts(workflow_id: workflow_id).first[:state]
    end

    def test_contract_run_claim_renewal_and_release
      clock = Struct.new(:now_ms).new(1_000)
      storage = build_contract_storage(clock: clock)
      workflow_id = contract_create_workflow(storage)
      first = storage.claim_workflow_run(id: workflow_id, owner_id: "first", lease_ms: 100)
      assert_raises(ArgumentError) { storage.renew_workflow_run(claim: first, until_ms: 1_050) }
      renewed = storage.renew_workflow_run(claim: first, until_ms: 1_200)
      assert_equal 1_200, renewed.lease_until_ms
      clock.now_ms = 1_100
      assert_raises(DAG::StaleRunClaimError) do
        storage.claim_workflow_run(id: workflow_id, owner_id: "second", lease_ms: 100)
      end
      assert_equal true, storage.release_workflow_run(claim: renewed)
      assert_raises(DAG::StaleRunClaimError) do
        storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
      end
      next_claim = storage.claim_workflow_run(id: workflow_id, owner_id: "second", lease_ms: 100)
      assert_operator next_claim.fencing_token, :>, renewed.fencing_token
    end

    def test_contract_two_runners_recover_after_takeover_once
      clock = Struct.new(:now_ms).new(1_000)
      storage = build_contract_storage(clock: clock)
      workflow_id = contract_create_workflow(storage)
      first = storage.claim_workflow_run(id: workflow_id, owner_id: "first", lease_ms: 100)
      runner_a = contract_claimed_runner(storage)
      runner_b = contract_claimed_runner(storage)
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running, claim: first)
      abandoned = storage.begin_attempt(workflow_id: workflow_id, revision: 1, node_id: :a,
        expected_node_state: :pending, attempt_number: 1, claim: first)
      clock.now_ms = 1_100
      second = storage.claim_workflow_run(id: workflow_id, owner_id: "second", lease_ms: 1_000)

      assert_raises(DAG::StaleRunClaimError) { runner_a.resume(workflow_id, claim: first) }
      assert_equal :completed, runner_b.resume(workflow_id, claim: second).state
      attempts = storage.list_attempts(workflow_id: workflow_id)
      assert_equal :aborted, attempts.find { |attempt| attempt[:attempt_id] == abandoned }[:state]
      assert_equal 2, attempts.count { |attempt| attempt[:state] == :committed }
      assert_equal 1, storage.read_events(workflow_id: workflow_id).count { |event| event.type == :workflow_completed }
    end

    private

    def contract_claimed_runner(storage)
      registry = DAG::StepTypeRegistry.new
      registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough,
        fingerprint_payload: {version: 1})
      registry.freeze!
      DAG::Runner.new(storage: storage, event_bus: DAG::Adapters::Null::EventBus.new,
        registry: registry, clock: DAG::Adapters::Stdlib::Clock.new,
        id_generator: DAG::Adapters::Stdlib::IdGenerator.new,
        fingerprint: DAG::Adapters::Stdlib::Fingerprint.new,
        serializer: DAG::Adapters::Stdlib::Serializer.new)
    end
  end
end
