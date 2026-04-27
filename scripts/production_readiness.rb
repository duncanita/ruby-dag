#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "securerandom"
require "time"
require "yaml"

require_relative "../lib/dag"

module ProductionReadiness
  class Failure < StandardError
  end

  # Test-only Clock: immutable, deterministic, advance via #at(ms) which
  # returns a new instance. Used by the determinism scenarios.
  class FixedClock
    include DAG::Ports::Clock

    def initialize(ms: 0)
      @ms = ms
      freeze
    end

    def now_ms = @ms

    def monotonic_ms = @ms

    def now = Time.at(@ms / 1000.0).utc

    def at(new_ms) = FixedClock.new(ms: new_ms)
  end

  # Test-only IdGenerator: deterministic counter with a configurable
  # prefix. Stateful, so not frozen — restricted to scripts/.
  class DeterministicIdGenerator
    include DAG::Ports::IdGenerator

    def initialize(prefix:)
      @prefix = prefix
      @n = 0
    end

    def call
      @n += 1
      "#{@prefix}-#{@n.to_s.rjust(8, "0")}"
    end
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
      @thresholds = load_thresholds(options[:thresholds_path])
    end

    def load_thresholds(path)
      return {profile: {}, breach_factor: BUDGET_BREACH_FACTOR} unless path

      unless File.exist?(path)
        warn("[#{Time.now.utc.iso8601}] WARN thresholds file not found: #{path} — perf budgets will be skipped")
        return {profile: {}, breach_factor: BUDGET_BREACH_FACTOR}
      end

      raw = YAML.safe_load_file(path, permitted_classes: [Symbol])
      profile_key = @options[:fast] ? "fast" : "full"
      profile = raw.dig("profiles", profile_key) || {}
      {
        profile: profile.fetch("scenarios", {}),
        breach_factor: profile.fetch("breach_factor", BUDGET_BREACH_FACTOR)
      }
    rescue => e
      warn("[#{Time.now.utc.iso8601}] WARN failed to load thresholds (#{path}): #{e.class}: #{e.message} — perf budgets will be skipped")
      {profile: {}, breach_factor: BUDGET_BREACH_FACTOR}
    end

    def threshold_wall_ms_for(scenario_key)
      entry = @thresholds[:profile][scenario_key.to_s]
      entry&.fetch("wall_ms", nil)
    end

    def threshold_breach_factor
      @thresholds[:breach_factor]
    end

    DEFAULT_SEED = 1
    DEFAULT_THRESHOLDS_PATH = File.expand_path("production_readiness.thresholds.yml", __dir__)

    def self.parse(argv)
      options = {
        fast: false,
        duration: nil,
        seed: DEFAULT_SEED,
        progress_interval: 10,
        report_file: nil,
        thresholds_path: DEFAULT_THRESHOLDS_PATH
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: scripts/production_readiness.rb [--fast] [--duration SECONDS] [--seed INTEGER|random] [--report-file PATH] [--thresholds PATH]"
        opts.on("--fast", "Run the short profile. Defaults to #{DEFAULT_FAST_SECONDS}s.") do
          options[:fast] = true
        end
        opts.on("--duration SECONDS", Integer, "Override duration in seconds.") do |seconds|
          options[:duration] = seconds
        end
        opts.on("--seed VALUE", "Deterministic random seed (Integer, default #{DEFAULT_SEED}). Pass `random` to opt back in to a fresh seed.") do |value|
          options[:seed] = (value.casecmp("random") == 0) ? Random.new_seed : Integer(value)
        end
        opts.on("--progress-interval SECONDS", Integer, "Progress print interval.") do |seconds|
          options[:progress_interval] = seconds
        end
        opts.on("--report-file PATH", "Write a machine-readable JSON report to PATH on exit.") do |path|
          options[:report_file] = path
        end
        opts.on("--thresholds PATH", "Override perf budgets file (default #{DEFAULT_THRESHOLDS_PATH}).") do |path|
          options[:thresholds_path] = path
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
      @started_at = Time.now.utc
      log("ruby-dag production readiness: duration=#{@options[:duration]}s seed=#{@options[:seed]} fast=#{@options[:fast]}")

      fixed_scenarios
      run_random_loop

      finished_at = Time.now.utc
      assert_minimum_metrics
      write_report(status: "pass", started_at: @started_at, finished_at: finished_at)
      log("PASS #{summary}")
      true
    rescue => e
      finished_at = Time.now.utc
      write_report(status: "fail", started_at: @started_at || finished_at, finished_at: finished_at, error: {class: e.class.name, message: e.message})
      raise
    end

    private

    def random_scenarios
      @random_scenarios ||= [
        -> { random_completed_workflow_scenario },
        -> { graph_fuzz_scenario },
        -> { flaky_retry_scenario },
        -> { terminal_failure_scenario },
        -> { waiting_idempotence_scenario },
        -> { bad_step_boundary_scenario },
        -> { crash_resume_scenario(:before_commit) },
        -> { crash_resume_scenario(:after_commit) },
        -> { mutation_pause_resume_scenario },
        -> { replace_subtree_resume_scenario },
        -> { storage_contract_edge_scenario },
        -> { retry_workflow_scenario },
        -> { subscriber_failure_scenario },
        -> { bus_overflow_scenario }
      ].freeze
    end

    def run_random_loop
      return if expired?

      random_scenarios.cycle do |scenario|
        break if expired?
        scenario.call
        progress_if_due
      end
    end

    def fixed_scenarios
      [
        -> { random_completed_workflow_scenario(nodes: 1, edge_probability: 0.0) },
        -> { random_completed_workflow_scenario(nodes: 2, edge_probability: 1.0) },
        -> { random_completed_workflow_scenario(nodes: 48, edge_probability: 0.08) },
        -> { graph_fuzz_scenario(nodes: 80, edge_probability: 0.05) },
        -> { flaky_retry_scenario(fail_until: 2, max_attempts: 3) },
        -> { terminal_failure_scenario(max_attempts: 2) },
        -> { waiting_idempotence_scenario },
        -> { bad_step_boundary_scenario },
        -> { crash_resume_scenario(:before_commit) },
        -> { crash_resume_scenario(:after_commit) },
        -> { mutation_pause_resume_scenario },
        -> { replace_subtree_resume_scenario },
        -> { storage_contract_edge_scenario },
        -> { retry_workflow_scenario },
        -> { subscriber_failure_scenario },
        -> { bus_overflow_scenario },
        -> { large_graph_scenario(shape: :chain_1000) },
        -> { large_graph_scenario(shape: :fanout_500) },
        -> { large_graph_scenario(shape: :diamond_50x50) },
        -> { long_lived_storage_scenario },
        -> { crash_matrix_scenario },
        -> { determinism_scenario }
      ].each do |scenario|
        break if expired?
        scenario.call
      end
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
      commit_state_mismatch_probes(storage, workflow_id)
      assert_storage_returns_are_isolated(storage, workflow_id)

      @metrics[:storage_edges] += 1
    end

    # Storage#commit_attempt enforces (result, node_state) coherence via
    # validate_node_state_for_result!. A bug there could let the runner
    # park a node in a state that contradicts the attempt outcome — a
    # silent durability hazard. Probe each forbidden combination on a
    # fresh in-flight attempt for node :b.
    def commit_state_mismatch_probes(storage, workflow_id)
      [
        [DAG::Success[value: :b], :failed],
        [DAG::Waiting[reason: :external], :committed],
        [DAG::Failure[error: {code: :synthetic}, retriable: false], :waiting]
      ].each do |result, bad_node_state|
        attempt_id = storage.begin_attempt(
          workflow_id: workflow_id,
          revision: 1,
          node_id: :b,
          expected_node_state: :pending,
          attempt_number: 1
        )
        assert_raises(ArgumentError) do
          storage.commit_attempt(
            attempt_id: attempt_id,
            result: result,
            node_state: bad_node_state,
            event: event(:node_committed, workflow_id: workflow_id, node_id: :b, attempt_id: attempt_id)
          )
        end
        # Recover: storage left node :b in :running. Reset for the next probe.
        storage.abort_running_attempts(workflow_id: workflow_id)
        @metrics[:commit_mismatches] += 1
      end
    end

    # Roadmap §R1 line 586 mandates Runner#retry_workflow resets :failed
    # nodes and "ricrea attempt nuovi". Group A added the harness; Group B
    # actually exercises it. The flaky step always fails, so we don't aim
    # for recovery — we verify the contract: prior :failed attempts get
    # marked :aborted (count_attempts excludes them so the per-node budget
    # restarts), workflow_retry_count increments, and a second exhaustion
    # raises WorkflowRetryExhaustedError.
    def retry_workflow_scenario
      definition = DAG::Workflow::Definition.new
        .add_node(:a, type: :flaky, config: {fail_until: 1_000})
      storage = DAG::Adapters::Memory::Storage.new
      workflow_id = create_workflow(storage, definition,
        runtime_profile: runtime_profile(max_attempts_per_node: 2, max_workflow_retries: 1))

      first = runner(storage).call(workflow_id)
      assert_equal(:failed, first.state, "initial run did not terminally fail")
      assert_equal(2, storage.count_attempts(workflow_id: workflow_id, revision: 1, node_id: :a),
        "first run did not exhaust per-node budget")

      second = runner(storage).retry_workflow(workflow_id)
      assert_equal(:failed, second.state, "retry did not re-fail terminally")
      assert_equal(1, storage.load_workflow(id: workflow_id)[:workflow_retry_count],
        "workflow_retry_count did not increment")

      attempts = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
      aborted = attempts.count { |a| a[:state] == :aborted }
      failed = attempts.count { |a| a[:state] == :failed }
      assert_equal(2, aborted, "prior failed attempts were not aborted on retry")
      assert_equal(2, failed, "second run did not produce 2 fresh failed attempts")
      assert_equal(2, storage.count_attempts(workflow_id: workflow_id, revision: 1, node_id: :a),
        "count_attempts did not exclude :aborted (per-node budget did not reset)")

      assert_raises(DAG::WorkflowRetryExhaustedError) { runner(storage).retry_workflow(workflow_id) }

      @metrics[:retries_exhausted] += 1
    end

    # Memory::EventBus#publish appends to the internal buffer first, then
    # iterates subscribers. A subscriber that raises propagates out through
    # the runner. The contract verified here:
    # - the storage event log already contains the event (publish-after-append),
    # - the runner surfaces the subscriber's exception (no swallowing),
    # - subsequent subscribers do not see the event (each-loop short-circuits).
    def subscriber_failure_scenario
      storage = DAG::Adapters::Memory::Storage.new
      event_bus = DAG::Adapters::Memory::EventBus.new
      tail_subscriber_seen = []
      raised_event_types = []

      event_bus.subscribe do |evt|
        raised_event_types << evt.type
        raise "synthetic subscriber failure"
      end
      event_bus.subscribe { |evt| tail_subscriber_seen << evt.type }

      definition = chain_definition(%i[a b], type: :probe)
      workflow_id = create_workflow(storage, definition)

      assert_raises(RuntimeError) { runner(storage, event_bus: event_bus).call(workflow_id) }

      assert_equal(1, raised_event_types.size, "raising subscriber received more than one event")
      assert_equal(:workflow_started, raised_event_types.first,
        "raising subscriber did not see the first published event")
      assert(tail_subscriber_seen.empty?, "downstream subscriber received an event after a prior raise")
      stored = storage.read_events(workflow_id: workflow_id)
      assert(stored.any? { |e| e.type == :workflow_started },
        "storage event log lost the event whose publish raised")

      @metrics[:subscriber_failures] += 1
    end

    # EventBus is a bounded ring buffer with FIFO drop. With a buffer
    # smaller than the workflow's event count, the runner must keep
    # running, the storage event log must remain whole, and only the
    # most recent N events must be retained on the bus.
    def bus_overflow_scenario
      buffer_size = 8
      storage = DAG::Adapters::Memory::Storage.new
      event_bus = DAG::Adapters::Memory::EventBus.new(buffer_size: buffer_size)
      definition = chain_definition(%i[a b c d e f g h], type: :probe)
      workflow_id = create_workflow(storage, definition)

      result = runner(storage, event_bus: event_bus).call(workflow_id)
      assert_equal(:completed, result.state, "overflow caused workflow not to complete")

      bus_events = event_bus.events
      stored_events = storage.read_events(workflow_id: workflow_id)

      assert(bus_events.size <= buffer_size, "bus retained more than buffer_size events: #{bus_events.size}")
      assert(stored_events.size > buffer_size,
        "test setup is wrong: storage produced fewer than buffer_size events")
      tail_of_storage = stored_events.last(bus_events.size).map(&:seq)
      assert_equal(tail_of_storage, bus_events.map(&:seq),
        "bus did not retain the most recent events (FIFO drop violated)")

      @metrics[:bus_overflows] += 1
    end

    # Three large-graph shapes with soft wallclock budgets. A 5x breach
    # of the budget fails the run — catches O(N^2) regressions that the
    # rest of the harness would only show as slowness.
    LARGE_GRAPH_SHAPES = {
      chain_1000: {nodes: 1_000, build: :chain},
      fanout_500: {nodes: 500, build: :fanout},
      diamond_50x50: {nodes: 50, build: :diamond}
    }.freeze
    BUDGET_BREACH_FACTOR = 5.0

    def large_graph_scenario(shape: nil)
      shape ||= LARGE_GRAPH_SHAPES.keys.sample(random: @rng)
      spec = LARGE_GRAPH_SHAPES.fetch(shape)
      definition = build_large_graph(spec[:build], spec[:nodes])

      storage = DAG::Adapters::Memory::Storage.new
      event_bus = DAG::Adapters::Memory::EventBus.new(buffer_size: definition.nodes.size * 4)
      workflow_id = create_workflow(storage, definition)

      started_ms = monotonic_ms
      result = runner(storage, event_bus: event_bus).call(workflow_id)
      elapsed_ms = monotonic_ms - started_ms

      assert_equal(:completed, result.state, "#{shape} did not complete")
      assert_committed(storage, workflow_id, definition)

      enforce_perf_budget("large_graph_#{shape}", elapsed_ms)

      @metrics[:large_graph_runs] += 1
      @metrics[:large_graph_nodes] += definition.nodes.size
    end

    def enforce_perf_budget(scenario_key, elapsed_ms)
      soft_ms = threshold_wall_ms_for(scenario_key)
      return unless soft_ms

      factor = threshold_breach_factor
      hard_budget = soft_ms * factor
      return if elapsed_ms <= hard_budget

      raise Failure, "#{scenario_key} elapsed #{elapsed_ms}ms exceeds #{hard_budget.to_i}ms (#{factor}x soft budget #{soft_ms}ms)"
    end

    def build_large_graph(kind, nodes)
      case kind
      when :chain
        chain_definition((0...nodes).map { |i| :"n#{i}" }, type: :noop)
      when :fanout
        definition = DAG::Workflow::Definition.new.add_node(:root, type: :noop)
        (0...nodes - 1).each do |i|
          leaf = :"l#{i}"
          definition = definition.add_node(leaf, type: :noop).add_edge(:root, leaf)
        end
        definition
      when :diamond
        definition = DAG::Workflow::Definition.new.add_node(:root, type: :noop)
        layer_a = (0...nodes).map { |i| :"a#{i}" }
        layer_b = (0...nodes).map { |i| :"b#{i}" }
        layer_a.each { |id| definition = definition.add_node(id, type: :noop).add_edge(:root, id) }
        layer_b.each { |id| definition = definition.add_node(id, type: :noop) }
        layer_a.each do |a|
          layer_b.each { |b| definition = definition.add_edge(a, b) }
        end
        definition = definition.add_node(:sink, type: :noop)
        layer_b.each { |b| definition = definition.add_edge(b, :sink) }
        definition
      else
        raise ArgumentError, "unknown large-graph kind: #{kind}"
      end
    end

    # Same Memory::Storage reused across N workflows. Memory::Storage retains
    # all events forever by design; the leak check is on Ruby heap (live
    # slots), not on the deliberate event retention. A leak would show up as
    # super-linear growth of live_slots per completed workflow.
    LONG_LIVED_BATCHES = 4
    LONG_LIVED_BATCH_SIZE = 50
    LONG_LIVED_LINEAR_RATIO = 6.0

    def long_lived_storage_scenario
      storage = DAG::Adapters::Memory::Storage.new
      definition = chain_definition(%i[a b c d e], type: :noop)

      GC.start
      slots_initial = GC.stat[:heap_live_slots]
      slots_after_first_batch = nil
      slots_after_last_batch = nil

      LONG_LIVED_BATCHES.times do |batch_index|
        LONG_LIVED_BATCH_SIZE.times do
          workflow_id = create_workflow(storage, definition)
          result = runner(storage).call(workflow_id)
          assert_equal(:completed, result.state, "long-lived batch workflow did not complete")
        end
        GC.start
        slots = GC.stat[:heap_live_slots]
        slots_after_first_batch ||= slots if batch_index == 0
        slots_after_last_batch = slots if batch_index == LONG_LIVED_BATCHES - 1
      end

      delta_initial = slots_after_first_batch - slots_initial
      delta_post = slots_after_last_batch - slots_after_first_batch
      growth_ratio = delta_initial.zero? ? 0.0 : delta_post.to_f / delta_initial

      assert(growth_ratio <= LONG_LIVED_LINEAR_RATIO,
        "long-lived storage shows super-linear heap growth: ratio=#{growth_ratio.round(2)} (delta_initial=#{delta_initial}, delta_post=#{delta_post}, threshold=#{LONG_LIVED_LINEAR_RATIO})")

      total_workflows = LONG_LIVED_BATCHES * LONG_LIVED_BATCH_SIZE
      total_events = storage.read_events(workflow_id: storage.instance_variable_get(:@state)[:workflows].keys.first).size
      assert(total_events.positive?, "first workflow's event log is empty after long-lived run")
      @metrics[:long_lived_runs] += 1
      @metrics[:long_lived_workflows] += total_workflows
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end

    # Exhaustive crash-injection matrix: every supported (method, phase)
    # tuple of CrashableStorage, on every meaningful node position of
    # three representative graph shapes. Each cell runs the workflow
    # until the crash, snapshots to a healthy storage, drives the
    # workflow to completion via call/resume, and asserts (a) the
    # workflow ends :completed, (b) workflow_started is not duplicated.
    CRASH_MATRIX = [
      # chain_3 (a -> b -> c) — every method × phase × representative node
      [:chain3, :begin_attempt, :before, {node_id: :a}],
      [:chain3, :begin_attempt, :after, {node_id: :a}],
      [:chain3, :begin_attempt, :before, {node_id: :b}],
      [:chain3, :begin_attempt, :after, {node_id: :b}],
      [:chain3, :begin_attempt, :before, {node_id: :c}],
      [:chain3, :begin_attempt, :after, {node_id: :c}],
      [:chain3, :commit_attempt, :before, {node_id: :a}],
      [:chain3, :commit_attempt, :after, {node_id: :a}],
      [:chain3, :commit_attempt, :before, {node_id: :b}],
      [:chain3, :commit_attempt, :after, {node_id: :b}],
      [:chain3, :commit_attempt, :before, {node_id: :c}],
      [:chain3, :commit_attempt, :after, {node_id: :c}],
      # CrashableStorage#append_event only intercepts the public Storage#append_event
      # path; per-attempt :node_* events go via append_event_internal during
      # commit_attempt (already covered by the commit_attempt rows above).
      # Workflow-lifecycle events (:workflow_started, :workflow_completed,
      # :workflow_failed, :workflow_paused, :workflow_waiting) are the ones
      # that actually flow through the public method and are crash-relevant.
      [:chain3, :append_event, :before, {event_type: :workflow_started}],
      [:chain3, :append_event, :after, {event_type: :workflow_started}],
      [:chain3, :append_event, :before, {event_type: :workflow_completed}],
      [:chain3, :append_event, :after, {event_type: :workflow_completed}],
      [:chain3, :transition_workflow_state, :before, {from: :pending, to: :running}],
      [:chain3, :transition_workflow_state, :after, {from: :pending, to: :running}],
      # single-node — only_node coverage
      [:single, :begin_attempt, :before, {node_id: :a}],
      [:single, :begin_attempt, :after, {node_id: :a}],
      [:single, :commit_attempt, :before, {node_id: :a}],
      [:single, :commit_attempt, :after, {node_id: :a}],
      # diamond (a -> {b,c} -> d) — join-leaf coverage
      [:diamond, :begin_attempt, :before, {node_id: :d}],
      [:diamond, :begin_attempt, :after, {node_id: :d}]
    ].freeze

    def crash_matrix_scenario
      CRASH_MATRIX.each { |cell| crash_matrix_cell(*cell) }
    end

    def crash_matrix_cell(shape, method, phase, criteria)
      label = "#{shape}/#{method}/#{phase}/#{criteria.inspect}"
      crash_on = {:method => method, phase => true}.merge(criteria)
      storage = DAG::Adapters::Memory::CrashableStorage.new(crash_on: crash_on)
      definition = build_crash_shape(shape)
      workflow_id = create_workflow(storage, definition)

      crashed = false
      begin
        runner(storage).call(workflow_id)
      rescue DAG::Adapters::Memory::SimulatedCrash
        crashed = true
      end
      raise Failure, "crash[#{label}] expected SimulatedCrash but none fired" unless crashed

      healthy = storage.snapshot_to_healthy
      drive_to_terminal(healthy, workflow_id, label)

      final_state = healthy.load_workflow(id: workflow_id)[:state]
      unless final_state == :completed
        raise Failure, "crash[#{label}] workflow ended in #{final_state.inspect}, expected :completed"
      end
      assert_committed(healthy, workflow_id, definition)
      assert_no_duplicate_workflow_started(healthy, workflow_id, label)

      @metrics[:crash_matrix_cells] += 1
    end

    def drive_to_terminal(storage, workflow_id, label, max_steps: 4)
      max_steps.times do
        state = storage.load_workflow(id: workflow_id)[:state]
        case state
        when :pending then runner(storage).call(workflow_id)
        when :running, :waiting, :paused then runner(storage).resume(workflow_id)
        when :completed then return
        else raise Failure, "crash[#{label}] cannot drive workflow from #{state.inspect}"
        end
      end
      raise Failure, "crash[#{label}] workflow did not converge in #{max_steps} steps"
    end

    def assert_no_duplicate_workflow_started(storage, workflow_id, label)
      events = storage.read_events(workflow_id: workflow_id)
      starts = events.count { |e| e.type == :workflow_started }
      return if starts == 1

      raise Failure, "crash[#{label}] :workflow_started emitted #{starts} times, expected 1"
    end

    # Determinism harness: two runs with identical inputs (same seed,
    # same FixedClock, same workflow_id, same definition) must produce
    # byte-identical normalized event logs. Catches non-determinism
    # introduced by Hash ordering, time leaks, accidental Random calls,
    # and similar.
    def determinism_scenario
      determinism_plain_run
      determinism_flaky_run
      determinism_waiting_resume_run
      @metrics[:determinism_runs] += 1
    end

    def determinism_plain_run
      definition = chain_definition(%i[a b c d e], type: :probe)
      run_a = run_for_determinism("plain-A", definition) { |runner, wid| runner.call(wid) }
      run_b = run_for_determinism("plain-A", definition) { |runner, wid| runner.call(wid) }
      assert_event_logs_equal(run_a, run_b, "determinism plain")
    end

    def determinism_flaky_run
      definition = DAG::Workflow::Definition.new
        .add_node(:a, type: :flaky, config: {fail_until: 2})
      runtime = runtime_profile(max_attempts_per_node: 3, max_workflow_retries: 1)
      run_a = run_for_determinism("flaky-A", definition, runtime_profile: runtime) { |runner, wid| runner.call(wid) }
      run_b = run_for_determinism("flaky-A", definition, runtime_profile: runtime) { |runner, wid| runner.call(wid) }
      assert_event_logs_equal(run_a, run_b, "determinism flaky")
    end

    def determinism_waiting_resume_run
      definition = DAG::Workflow::Definition.new.add_node(:a, type: :waiting)
      run_a = run_for_determinism("waiting-A", definition) do |runner_first, wid, build_runner|
        first_result = runner_first.call(wid)
        raise Failure, "determinism waiting setup: workflow did not enter :waiting" unless first_result.state == :waiting
        runner_second = build_runner.call(1500)
        runner_second.resume(wid)
      end
      run_b = run_for_determinism("waiting-A", definition) do |runner_first, wid, build_runner|
        runner_first.call(wid)
        runner_second = build_runner.call(1500)
        runner_second.resume(wid)
      end
      assert_event_logs_equal(run_a, run_b, "determinism waiting+resume")
    end

    def run_for_determinism(workflow_id, definition, runtime_profile: nil)
      storage = DAG::Adapters::Memory::Storage.new
      event_bus = DAG::Adapters::Memory::EventBus.new(buffer_size: 256)
      clock = FixedClock.new(ms: 0)
      id_gen = DeterministicIdGenerator.new(prefix: workflow_id)

      build_runner = ->(at_ms) {
        DAG::Runner.new(
          storage: storage,
          event_bus: event_bus,
          registry: registry,
          clock: clock.at(at_ms),
          id_generator: id_gen,
          fingerprint: @fingerprint,
          serializer: @serializer
        )
      }

      storage.create_workflow(
        id: workflow_id,
        initial_definition: definition,
        initial_context: {},
        runtime_profile: runtime_profile || self.runtime_profile
      )
      yield(build_runner.call(0), workflow_id, build_runner)

      storage.read_events(workflow_id: workflow_id).map { |e| event_to_h_for_compare(e) }
    end

    def event_to_h_for_compare(event)
      {
        seq: event.seq,
        type: event.type,
        revision: event.revision,
        node_id: event.node_id,
        at_ms: event.at_ms,
        payload: event.payload
      }
    end

    def assert_event_logs_equal(run_a, run_b, label)
      return if run_a == run_b

      diff = []
      [run_a.size, run_b.size].max.times do |i|
        a = run_a[i]
        b = run_b[i]
        next if a == b
        diff << "[#{i}] A=#{a.inspect} B=#{b.inspect}"
        break if diff.size >= 3
      end
      raise Failure, "#{label}: event logs diverged (#{run_a.size} vs #{run_b.size}) — #{diff.join(" | ")}"
    end

    def build_crash_shape(shape)
      case shape
      when :chain3 then chain_definition(%i[a b c], type: :probe)
      when :single then DAG::Workflow::Definition.new.add_node(:a, type: :probe)
      when :diamond
        DAG::Workflow::Definition.new
          .add_node(:a, type: :probe).add_node(:b, type: :probe)
          .add_node(:c, type: :probe).add_node(:d, type: :probe)
          .add_edge(:a, :b).add_edge(:a, :c)
          .add_edge(:b, :d).add_edge(:c, :d)
      else raise ArgumentError, "unknown crash shape: #{shape}"
      end
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
    rescue Failure
      raise
    rescue => e
      raise Failure.new("expected #{error_class}, got #{e.class}: #{e.message}").tap { |f| f.set_backtrace(e.backtrace) }
    end

    METRIC_FLOORS = {
      completed_workflows: 1.0,
      retry_recoveries: 0.2,
      terminal_failures: 0.2,
      waiting_workflows: 0.2,
      boundary_failures: 0.2,
      crash_resumes: 0.2,
      mutations: 0.2,
      storage_edges: 0.2,
      retries_exhausted: 0.1,
      commit_mismatches: 0.3,
      subscriber_failures: 0.1,
      bus_overflows: 0.1,
      large_graph_runs: 0.0, # always >=1 from fixed_scenarios (3 shapes); duration-independent
      long_lived_runs: 0.0,  # always >=1 from fixed_scenarios; duration-independent
      crash_matrix_cells: 0.0, # always >= |CRASH_MATRIX| from fixed_scenarios; duration-independent
      determinism_runs: 0.0  # always >=1 from fixed_scenarios; duration-independent
    }.freeze

    def assert_minimum_metrics
      duration = @options.fetch(:duration)
      shortfalls = METRIC_FLOORS.filter_map do |metric, per_second|
        floor = [(per_second * duration).floor, 1].max
        actual = @metrics[metric]
        next if actual >= floor

        "#{metric}=#{actual} (floor #{floor})"
      end
      return if shortfalls.empty?

      raise Failure, "metric coverage below floor: #{shortfalls.join(", ")}"
    end

    def write_report(status:, started_at:, finished_at:, error: nil)
      path = @options[:report_file]
      return unless path

      report = {
        status: status,
        seed: @options[:seed],
        duration_s: @options.fetch(:duration),
        fast: @options[:fast],
        started_at: started_at.iso8601,
        finished_at: finished_at.iso8601,
        elapsed_s: (finished_at - started_at).round(3),
        metrics: @metrics.sort.to_h
      }
      report[:error] = error if error

      File.write(path, JSON.pretty_generate(report) + "\n")
    rescue => e
      warn("[#{Time.now.utc.iso8601}] WARN failed to write --report-file #{path}: #{e.class}: #{e.message}")
    end
  end
end

if __FILE__ == $0
  begin
    options = ProductionReadiness::Harness.parse(ARGV)
    ProductionReadiness::Harness.new(options).run
  rescue => e
    warn("[#{Time.now.utc.iso8601}] FAIL #{e.class}: #{e.message}")
    warn(e.backtrace.join("\n")) if e.backtrace
    exit 1
  end
end
