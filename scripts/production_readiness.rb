#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "securerandom"
require "time"

require_relative "../lib/dag"

module ProductionReadiness
  class Failure < StandardError
  end

  class ProbeStep < DAG::Step::Base
    def call(input)
      context = input.context.to_h
      DAG::Success[
        value: {
          node: input.node_id,
          attempt_number: input.attempt_number,
          context_size: context.size
        },
        context_patch: {
          input.node_id => {
            attempt_number: input.attempt_number,
            predecessor_count: context.size,
            config_marker: config.fetch(:marker, "probe")
          }
        },
        metadata: {step: :probe}
      ]
    end
  end

  class FlakyStep < DAG::Step::Base
    def call(input)
      fail_until = config.fetch(:fail_until, 1)
      if input.attempt_number <= fail_until
        return DAG::Failure[
          error: {
            code: :synthetic_retry,
            node: input.node_id,
            attempt_number: input.attempt_number
          },
          retriable: true
        ]
      end

      DAG::Success[
        value: {node: input.node_id, recovered_at: input.attempt_number},
        context_patch: {input.node_id => {attempt_number: input.attempt_number}},
        metadata: {step: :flaky}
      ]
    end
  end

  class WaitingStep < DAG::Step::Base
    def call(input)
      DAG::Waiting[
        reason: config.fetch(:reason, :external),
        resume_token: {node: input.node_id, attempt_number: input.attempt_number},
        not_before_ms: config[:not_before_ms],
        metadata: {step: :waiting}
      ]
    end
  end

  class BadReturnStep < DAG::Step::Base
    def call(_input)
      :not_a_result
    end
  end

  class RaisingStep < DAG::Step::Base
    def call(_input)
      raise ArgumentError, "synthetic production-readiness exception"
    end
  end

  class MutationProposalStep < DAG::Step::Base
    def call(input)
      mutation = DAG::ProposedMutation[
        kind: :invalidate,
        target_node_id: config.fetch(:target_node_id)
      ]
      DAG::Success[
        value: {node: input.node_id, proposed_mutations: 1},
        context_patch: {input.node_id => {attempt_number: input.attempt_number}},
        proposed_mutations: [mutation],
        metadata: {step: :mutation_proposal}
      ]
    end
  end

  class Harness
    DEFAULT_FAST_SECONDS = 120
    DEFAULT_FULL_SECONDS = 3600
    FAST_NODE_RANGE = 4..24
    FULL_NODE_RANGE = 12..100

    def initialize(options)
      @options = options
      @rng = Random.new(options.fetch(:seed))
      @deadline = monotonic_seconds + options.fetch(:duration)
      @metrics = Hash.new(0)
      @last_progress_at = monotonic_seconds
      @fingerprint = DAG::Adapters::Stdlib::Fingerprint.new
      @serializer = DAG::Adapters::Stdlib::Serializer.new
      @clock = DAG::Adapters::Stdlib::Clock.new
      @id_generator = DAG::Adapters::Stdlib::IdGenerator.new
    end

    def self.parse(argv)
      options = {
        fast: false,
        duration: nil,
        seed: Random.new_seed,
        progress_interval: 10
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: scripts/production_readiness.rb [--fast] [--duration SECONDS] [--seed INTEGER]"
        opts.on("--fast", "Run the short profile. Defaults to #{DEFAULT_FAST_SECONDS}s.") do
          options[:fast] = true
        end
        opts.on("--duration SECONDS", Integer, "Override duration in seconds.") do |seconds|
          options[:duration] = seconds
        end
        opts.on("--seed INTEGER", Integer, "Deterministic random seed.") do |seed|
          options[:seed] = seed
        end
        opts.on("--progress-interval SECONDS", Integer, "Progress print interval.") do |seconds|
          options[:progress_interval] = seconds
        end
        opts.on("-h", "--help", "Show help.") do
          puts opts
          exit 0
        end
      end
      parser.parse!(argv)

      options[:duration] ||= options[:fast] ? DEFAULT_FAST_SECONDS : DEFAULT_FULL_SECONDS
      raise ArgumentError, "--duration must be positive" unless options[:duration].positive?
      raise ArgumentError, "--progress-interval must be positive" unless options[:progress_interval].positive?

      options
    end

    def run
      log("ruby-dag production readiness: duration=#{@options[:duration]}s seed=#{@options[:seed]} fast=#{@options[:fast]}")

      fixed_scenarios
      until expired?
        random_completed_workflow_scenario
        graph_fuzz_scenario
        flaky_retry_scenario
        terminal_failure_scenario
        waiting_idempotence_scenario
        bad_step_boundary_scenario
        crash_resume_scenario(:before_commit)
        crash_resume_scenario(:after_commit)
        mutation_pause_resume_scenario
        replace_subtree_resume_scenario
        storage_contract_edge_scenario
        progress_if_due
      end

      log("PASS #{summary}")
      true
    end

    private

    def fixed_scenarios
      random_completed_workflow_scenario(nodes: 1, edge_probability: 0.0)
      random_completed_workflow_scenario(nodes: 2, edge_probability: 1.0)
      random_completed_workflow_scenario(nodes: 48, edge_probability: 0.08)
      graph_fuzz_scenario(nodes: 80, edge_probability: 0.05)
      flaky_retry_scenario(fail_until: 2, max_attempts: 3)
      terminal_failure_scenario(max_attempts: 2)
      waiting_idempotence_scenario
      bad_step_boundary_scenario
      crash_resume_scenario(:before_commit)
      crash_resume_scenario(:after_commit)
      mutation_pause_resume_scenario
      replace_subtree_resume_scenario
      storage_contract_edge_scenario
    end

    def random_completed_workflow_scenario(nodes: nil, edge_probability: nil)
      nodes ||= @rng.rand(node_range)
      edge_probability ||= @options[:fast] ? @rng.rand(0.02..0.18) : @rng.rand(0.01..0.12)
      definition = random_definition(nodes: nodes, edge_probability: edge_probability)
      storage = DAG::Adapters::Memory::Storage.new
      event_bus = DAG::Adapters::Memory::EventBus.new(buffer_size: [nodes * 4, 1000].max)
      workflow_id = create_workflow(storage, definition)

      result = runner(storage, event_bus: event_bus).call(workflow_id)

      assert_equal(:completed, result.state, "random workflow did not complete")
      assert_committed(storage, workflow_id, definition)
      assert_event_log(storage, workflow_id)
      assert_event_bus_frozen(event_bus)
      assert_storage_returns_are_isolated(storage, workflow_id)

      @metrics[:completed_workflows] += 1
      @metrics[:completed_nodes] += nodes
    end

    def graph_fuzz_scenario(nodes: nil, edge_probability: nil)
      nodes ||= @rng.rand(node_range)
      edge_probability ||= @rng.rand(0.01..0.2)
      definition = random_definition(nodes: nodes, edge_probability: edge_probability)
      graph = definition.graph
      order = graph.topological_order
      position = order.each_with_index.to_h

      assert_equal(nodes, graph.node_count, "node count drifted")
      graph.each_edge do |edge|
        assert(position.fetch(edge.from) < position.fetch(edge.to), "topological order violated by #{edge.inspect}")
        assert(edge.metadata.frozen?, "edge metadata is not frozen")
      end

      h1 = definition.to_h
      h2 = DAG.deep_dup(h1)
      assert_equal(@fingerprint.compute(h1), @fingerprint.compute(h2), "fingerprint is not stable")
      assert_raises(DAG::CycleError) { graph.dup.add_edge(order.last, order.first) } if nodes > 1

      @metrics[:graph_fuzzes] += 1
      @metrics[:graph_nodes] += nodes
    end

    def flaky_retry_scenario(fail_until: nil, max_attempts: nil)
      fail_until ||= @rng.rand(1..3)
      max_attempts ||= fail_until + 1
      definition = DAG::Workflow::Definition.new
        .add_node(:a, type: :flaky, config: {fail_until: fail_until})
      storage = DAG::Adapters::Memory::Storage.new
      workflow_id = create_workflow(storage, definition, runtime_profile: runtime_profile(max_attempts_per_node: max_attempts))

      result = runner(storage).call(workflow_id)

      assert_equal(:completed, result.state, "flaky workflow did not recover")
      attempts = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
      assert_equal((1..(fail_until + 1)).to_a, attempts.map { |attempt| attempt[:attempt_number] }, "attempt numbers drifted")
      assert_equal([:failed] * fail_until + [:committed], attempts.map { |attempt| attempt[:state] }, "unexpected retry states")

      @metrics[:retry_recoveries] += 1
      @metrics[:attempts] += attempts.size
    end

    def terminal_failure_scenario(max_attempts: nil)
      max_attempts ||= @rng.rand(1..3)
      definition = DAG::Workflow::Definition.new
        .add_node(:a, type: :flaky, config: {fail_until: max_attempts + 100})
      storage = DAG::Adapters::Memory::Storage.new
      workflow_id = create_workflow(storage, definition, runtime_profile: runtime_profile(max_attempts_per_node: max_attempts))

      result = runner(storage).call(workflow_id)

      assert_equal(:failed, result.state, "terminal failure workflow did not fail")
      attempts = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
      assert_equal(max_attempts, attempts.size, "terminal failure did not stop at budget")
      assert_equal((1..max_attempts).to_a, attempts.map { |attempt| attempt[:attempt_number] }, "failure attempt numbers drifted")
      assert_equal(:failed, storage.load_workflow(id: workflow_id)[:state], "workflow state did not persist failed")

      @metrics[:terminal_failures] += 1
      @metrics[:attempts] += attempts.size
    end

    def waiting_idempotence_scenario
      definition = DAG::Workflow::Definition.new
        .add_node(:a, type: :waiting, config: {reason: :external_io, not_before_ms: @clock.now_ms + 1000})
      storage = DAG::Adapters::Memory::Storage.new
      workflow_id = create_workflow(storage, definition)

      result = runner(storage).call(workflow_id)
      assert_equal(:waiting, result.state, "waiting workflow did not wait")
      assert_equal(:waiting, storage.load_workflow(id: workflow_id)[:state], "waiting state did not persist")
      assert_raises(DAG::StaleStateError) { runner(storage).call(workflow_id) }

      resumed = runner(storage).resume(workflow_id)
      assert_equal(:waiting, resumed.state, "waiting resume should stay waiting without external resolution")
      attempts = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
      assert_equal(1, attempts.size, "resume re-ran a waiting node")

      @metrics[:waiting_workflows] += 1
    end

    def bad_step_boundary_scenario
      [
        [:bad_return, :step_bad_return],
        [:raising, :step_raised]
      ].each do |type, code|
        definition = DAG::Workflow::Definition.new.add_node(:a, type: type)
        storage = DAG::Adapters::Memory::Storage.new
        workflow_id = create_workflow(storage, definition)

        result = runner(storage).call(workflow_id)
        attempt = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).last

        assert_equal(:failed, result.state, "#{type} did not fail workflow")
        assert_equal(code, attempt[:result].error.fetch(:code), "#{type} mapped to wrong error code")
      end

      @metrics[:boundary_failures] += 2
    end

    def crash_resume_scenario(phase)
      crash_on = case phase
      when :before_commit then {method: :commit_attempt, node_id: :b, before_commit: true}
      when :after_commit then {method: :commit_attempt, node_id: :b, after_commit: true}
      else raise ArgumentError, "unknown crash phase: #{phase.inspect}"
      end

      storage = DAG::Adapters::Memory::CrashableStorage.new(crash_on: crash_on)
      definition = chain_definition(%i[a b c], type: :probe)
      workflow_id = create_workflow(storage, definition)

      assert_raises(DAG::Adapters::Memory::SimulatedCrash) { runner(storage).call(workflow_id) }

      healthy_storage = storage.snapshot_to_healthy
      result = runner(healthy_storage).resume(workflow_id)
      assert_equal(:completed, result.state, "crash #{phase} did not resume to completion")
      assert_committed(healthy_storage, workflow_id, definition)

      b_attempt_states = healthy_storage
        .list_attempts(workflow_id: workflow_id, revision: 1, node_id: :b)
        .map { |attempt| attempt[:state] }
      expected = (phase == :before_commit) ? %i[aborted committed] : [:committed]
      assert_equal(expected, b_attempt_states, "unexpected b attempt states after #{phase} crash")

      @metrics[:crash_resumes] += 1
    end

    def mutation_pause_resume_scenario
      definition = DAG::Workflow::Definition.new
        .add_node(:a, type: :probe)
        .add_node(:b, type: :mutation_proposal, config: {target_node_id: :c})
        .add_node(:c, type: :probe)
        .add_edge(:a, :b)
        .add_edge(:b, :c)
      storage = DAG::Adapters::Memory::Storage.new
      event_bus = DAG::Adapters::Memory::EventBus.new
      workflow_id = create_workflow(storage, definition)

      paused = runner(storage, event_bus: event_bus).call(workflow_id)
      assert_equal(:paused, paused.state, "mutation proposal did not pause workflow")

      apply = mutation_service(storage, event_bus).apply(
        workflow_id: workflow_id,
        mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :c],
        expected_revision: 1
      )
      assert_equal(2, apply.revision, "invalidate did not append revision")
      assert_equal([:c], apply.invalidated_node_ids, "invalidate reset wrong nodes")

      result = runner(storage, event_bus: event_bus).resume(workflow_id)
      assert_equal(:completed, result.state, "resume after invalidate did not complete")
      assert_equal(:committed, storage.load_node_states(workflow_id: workflow_id, revision: 2).fetch(:c), "c was not recomputed")

      @metrics[:mutations] += 1
    end

    def replace_subtree_resume_scenario
      definition = DAG::Workflow::Definition.new
        .add_node(:a, type: :probe)
        .add_node(:b, type: :probe)
        .add_node(:c, type: :probe)
        .add_node(:d, type: :probe)
        .add_edge(:a, :b)
        .add_edge(:a, :c)
        .add_edge(:b, :d)
        .add_edge(:c, :d)
      storage = DAG::Adapters::Memory::Storage.new
      event_bus = DAG::Adapters::Memory::EventBus.new
      workflow_id = create_committed_workflow(storage, definition)

      replacement = DAG::ReplacementGraph[
        graph: DAG::Graph.new.add_node(:b_prime).freeze,
        entry_node_ids: [:b_prime],
        exit_node_ids: [:b_prime]
      ]
      apply = mutation_service(storage, event_bus).apply(
        workflow_id: workflow_id,
        mutation: DAG::ProposedMutation[kind: :replace_subtree, target_node_id: :b, replacement_graph: replacement],
        expected_revision: 1
      )

      assert_equal(2, apply.revision, "replace_subtree did not append revision")
      assert(apply.definition.has_node?(:b_prime), "replacement node missing")
      refute(apply.definition.has_node?(:b), "replaced node still present")

      states_after_apply = storage.load_node_states(workflow_id: workflow_id, revision: 2)
      assert_equal(:committed, states_after_apply.fetch(:a), "preserved root drifted from :committed")
      assert_equal(:committed, states_after_apply.fetch(:c), "preserved parallel branch drifted from :committed")
      assert_equal(:invalidated, states_after_apply.fetch(:d), "preserved-impacted node must be :invalidated post-apply")
      assert_equal(:pending, states_after_apply.fetch(:b_prime), "newly introduced replacement node must be :pending post-apply")

      result = runner(storage, event_bus: event_bus).resume(workflow_id)
      assert_equal(:completed, result.state, "resume after replace_subtree did not complete")
      states_after_resume = storage.load_node_states(workflow_id: workflow_id, revision: 2)
      assert_equal(:committed, states_after_resume.fetch(:b_prime), "replacement node did not run")
      assert_equal(:committed, states_after_resume.fetch(:d), "invalidated join did not re-execute")

      @metrics[:mutations] += 1
    end

    def storage_contract_edge_scenario
      storage = DAG::Adapters::Memory::Storage.new
      definition = chain_definition(%i[a b], type: :probe)
      workflow_id = create_workflow(storage, definition)

      attempt_id = storage.begin_attempt(
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        expected_node_state: :pending,
        attempt_number: 7
      )
      event = event(:node_committed, workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: :a, context_patch: {a: {nested: [1, 2, 3]}}],
        node_state: :committed,
        event: event
      )

      assert_equal(7, storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a).last[:attempt_number], "storage rewrote attempt_number")
      assert_raises(DAG::StaleStateError) do
        storage.commit_attempt(
          attempt_id: attempt_id,
          result: DAG::Success[value: :late],
          node_state: :committed,
          event: event(:node_committed, workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id)
        )
      end
      assert_raises(DAG::StaleStateError) do
        storage.begin_attempt(
          workflow_id: workflow_id,
          revision: 1,
          node_id: :a,
          expected_node_state: :pending,
          attempt_number: 8
        )
      end
      assert_storage_returns_are_isolated(storage, workflow_id)

      @metrics[:storage_edges] += 1
    end

    def random_definition(nodes:, edge_probability:)
      definition = DAG::Workflow::Definition.new
      node_ids = Array.new(nodes) { |index| :"n#{index}" }
      node_ids.each do |node_id|
        definition = definition.add_node(node_id, type: :probe, config: {marker: "m#{@rng.rand(1000)}"})
      end

      (1...nodes).each do |to_index|
        from_index = @rng.rand(0...to_index)
        definition = definition.add_edge(node_ids.fetch(from_index), node_ids.fetch(to_index), weight: @rng.rand(1..10))
      end

      (0...nodes).each do |from_index|
        ((from_index + 1)...nodes).each do |to_index|
          next if @rng.rand >= edge_probability

          definition = definition.add_edge(node_ids.fetch(from_index), node_ids.fetch(to_index), weight: @rng.rand(1..10))
        end
      end

      definition
    end

    def chain_definition(node_ids, type:)
      node_ids.each_with_index.reduce(DAG::Workflow::Definition.new) do |definition, (node_id, index)|
        next_definition = definition.add_node(node_id, type: type)
        (index == 0) ? next_definition : next_definition.add_edge(node_ids.fetch(index - 1), node_id)
      end
    end

    def registry
      @registry ||= begin
        reg = DAG::StepTypeRegistry.new
        reg.register(name: :probe, klass: ProbeStep, fingerprint_payload: {v: 1})
        reg.register(name: :flaky, klass: FlakyStep, fingerprint_payload: {v: 1})
        reg.register(name: :waiting, klass: WaitingStep, fingerprint_payload: {v: 1})
        reg.register(name: :bad_return, klass: BadReturnStep, fingerprint_payload: {v: 1})
        reg.register(name: :raising, klass: RaisingStep, fingerprint_payload: {v: 1})
        reg.register(name: :mutation_proposal, klass: MutationProposalStep, fingerprint_payload: {v: 1})
        reg.register(name: :noop, klass: DAG::BuiltinSteps::Noop, fingerprint_payload: {v: 1})
        reg.freeze!
        reg
      end
    end

    def runner(storage, event_bus: DAG::Adapters::Null::EventBus.new)
      DAG::Runner.new(
        storage: storage,
        event_bus: event_bus,
        registry: registry,
        clock: @clock,
        id_generator: @id_generator,
        fingerprint: @fingerprint,
        serializer: @serializer
      )
    end

    def mutation_service(storage, event_bus)
      DAG::MutationService.new(storage: storage, event_bus: event_bus, clock: @clock)
    end

    def create_workflow(storage, definition, initial_context: {}, runtime_profile: nil)
      workflow_id = SecureRandom.uuid
      storage.create_workflow(
        id: workflow_id,
        initial_definition: definition,
        initial_context: initial_context,
        runtime_profile: runtime_profile || self.runtime_profile
      )
      workflow_id
    end

    def create_committed_workflow(storage, definition)
      workflow_id = create_workflow(storage, definition)
      definition.topological_order.each do |node_id|
        attempt_id = storage.begin_attempt(
          workflow_id: workflow_id,
          revision: definition.revision,
          node_id: node_id,
          expected_node_state: :pending,
          attempt_number: 1
        )
        storage.commit_attempt(
          attempt_id: attempt_id,
          result: DAG::Success[value: node_id, context_patch: {node_id => true}],
          node_state: :committed,
          event: event(:node_committed, workflow_id: workflow_id, node_id: node_id, attempt_id: attempt_id)
        )
      end
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)
      workflow_id
    end

    def runtime_profile(max_attempts_per_node: 3, max_workflow_retries: 1)
      DAG::RuntimeProfile[
        durability: :ephemeral,
        max_attempts_per_node: max_attempts_per_node,
        max_workflow_retries: max_workflow_retries,
        event_bus_kind: :memory
      ]
    end

    def event(type, workflow_id:, node_id: nil, attempt_id: nil, payload: {})
      DAG::Event[
        type: type,
        workflow_id: workflow_id,
        revision: 1,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: @clock.now_ms,
        payload: payload
      ]
    end

    def assert_committed(storage, workflow_id, definition)
      states = storage.load_node_states(workflow_id: workflow_id, revision: definition.revision)
      assert_equal(definition.nodes.sort_by(&:to_s), states.keys.sort_by(&:to_s), "node states key set drifted")
      assert(states.values.all? { |state| state == :committed }, "not all nodes committed: #{states.inspect}")
      definition.each_node do |node_id|
        attempts = storage.list_attempts(workflow_id: workflow_id, revision: definition.revision, node_id: node_id)
        assert(attempts.any? { |attempt| attempt[:state] == :committed }, "node #{node_id} has no committed attempt")
      end
    end

    def assert_event_log(storage, workflow_id)
      events = storage.read_events(workflow_id: workflow_id)
      seqs = events.map(&:seq)
      assert_equal(seqs.sort, seqs, "event seq is not monotonic")
      assert_equal(seqs.uniq, seqs, "event seq contains duplicates")
      assert_equal(:workflow_started, events.first&.type, "first event is not workflow_started")
      assert_equal(1, events.count { |event| event.type == :workflow_started }, "workflow_started was emitted more than once")
      assert(%i[workflow_completed workflow_failed workflow_waiting workflow_paused].include?(events.last&.type), "last event is not terminal")
      events.each { |event| assert(event.frozen? && event.payload.frozen?, "event is not deeply frozen") }
    end

    def assert_event_bus_frozen(event_bus)
      event_bus.events.each { |event| assert(event.frozen? && event.payload.frozen?, "event bus exposed mutable event") }
    end

    def assert_storage_returns_are_isolated(storage, workflow_id)
      workflow = storage.load_workflow(id: workflow_id)
      assert(workflow.frozen?, "load_workflow returned mutable workflow")
      assert_raises(FrozenError) { workflow[:state] = :corrupt }
      assert_equal(storage.load_workflow(id: workflow_id)[:state], workflow[:state], "workflow mutation leaked into storage")

      definition = storage.load_current_definition(id: workflow_id)
      states = storage.load_node_states(workflow_id: workflow_id, revision: definition.revision)
      assert(states.frozen?, "load_node_states returned mutable hash")
      assert_raises(FrozenError) { states[states.keys.first] = :corrupt } unless states.empty?

      attempts = storage.list_attempts(workflow_id: workflow_id)
      assert(attempts.frozen?, "list_attempts returned mutable array")
      attempts.each { |attempt| assert(attempt.frozen?, "attempt record is mutable") }
      assert_raises(FrozenError) { attempts << {} }

      events = storage.read_events(workflow_id: workflow_id)
      assert(events.frozen?, "read_events returned mutable array")
      assert_raises(FrozenError) { events << :corrupt }
    end

    def node_range
      @options[:fast] ? FAST_NODE_RANGE : FULL_NODE_RANGE
    end

    def expired?
      monotonic_seconds >= @deadline
    end

    def progress_if_due
      now = monotonic_seconds
      return if now - @last_progress_at < @options[:progress_interval]

      @last_progress_at = now
      log("progress #{summary}")
    end

    def summary
      elapsed = @options.fetch(:duration) - [@deadline - monotonic_seconds, 0].max
      ordered = @metrics.keys.sort.map { |key| "#{key}=#{@metrics[key]}" }.join(" ")
      "elapsed=#{format("%.1f", elapsed)}s #{ordered}"
    end

    def monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(message)
      puts("[#{Time.now.utc.iso8601}] #{message}")
    end

    def assert(condition, message)
      raise Failure, message unless condition
    end

    def refute(condition, message)
      assert(!condition, message)
    end

    def assert_equal(expected, actual, message)
      return if expected == actual

      raise Failure, "#{message}: expected #{expected.inspect}, got #{actual.inspect}"
    end

    def assert_raises(error_class)
      yield
      raise Failure, "expected #{error_class}, nothing was raised"
    rescue error_class
      true
    rescue => e
      raise Failure, "expected #{error_class}, got #{e.class}: #{e.message}"
    end
  end
end

begin
  options = ProductionReadiness::Harness.parse(ARGV)
  ProductionReadiness::Harness.new(options).run
rescue => e
  warn("[#{Time.now.utc.iso8601}] FAIL #{e.class}: #{e.message}")
  warn(e.backtrace.join("\n")) if e.backtrace
  exit 1
end
