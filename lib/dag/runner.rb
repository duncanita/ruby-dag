# frozen_string_literal: true

module DAG
  # Deterministic kernel runner. All collaborators are injected; nothing is
  # singleton or default. The runner is frozen after construction.
  #
  # The lifecycle of `#call(workflow_id)`:
  #
  #   1. CAS the workflow from {pending, waiting, paused} -> running.
  #   2. Append `workflow_started` if this is the first ever run.
  #   3. Loop: pick eligible nodes (predecessors all committed, state pending),
  #      ordered by topological order; begin_attempt, build StepInput, call
  #      the step, commit_attempt + transition node state + append the
  #      matching event for each outcome. Bail on a non-retriable failure.
  #   4. Resolve final workflow state: completed / waiting / paused / failed.
  #
  # See Roadmap v3.4 R1 for the binding algorithm.
  REQUIRED_RUNNER_DEPENDENCIES = %i[storage event_bus registry clock id_generator fingerprint serializer].freeze

  class Runner
    attr_reader :storage, :event_bus, :registry, :clock, :id_generator, :fingerprint, :serializer

    def initialize(storage:, event_bus:, registry:, clock:, id_generator:, fingerprint:, serializer:)
      missing = {storage:, event_bus:, registry:, clock:, id_generator:, fingerprint:, serializer:}
        .select { |_, v| v.nil? }.keys
      raise ArgumentError, "Runner requires: #{missing.join(", ")}" unless missing.empty?

      @storage = storage
      @event_bus = event_bus
      @registry = registry
      @clock = clock
      @id_generator = id_generator
      @fingerprint = fingerprint
      @serializer = serializer
      freeze
    end

    def call(workflow_id)
      workflow = transition_to_running(workflow_id)
      definition = @storage.load_current_definition(id: workflow_id)
      runtime_profile = workflow[:runtime_profile]
      revision = definition.revision

      append_workflow_started_once(workflow_id, revision, workflow)

      paused = false
      failed = false
      loop do
        eligible = eligible_nodes(workflow_id, revision, definition)
        break if eligible.empty?

        eligible.each do |node_id|
          outcome = execute_node(workflow_id, revision, definition, node_id, runtime_profile)
          case outcome
          when :paused
            paused = true
            break
          when :failed_terminal
            failed = true
            break
          end
        end

        break if paused || failed
      end

      finalize(workflow_id, revision, paused: paused, failed: failed)
    end

    def retry_workflow(workflow_id)
      workflow = @storage.load_workflow(id: workflow_id)
      raise StaleStateError, "workflow not in :failed state (#{workflow[:state].inspect})" unless workflow[:state] == :failed

      retry_count = workflow[:workflow_retry_count]
      max = workflow[:runtime_profile].max_workflow_retries
      raise WorkflowRetryExhaustedError, "workflow retries exhausted (#{retry_count}/#{max})" if retry_count >= max

      @storage.increment_workflow_retry(id: workflow_id)
      @storage.reset_failed_nodes(id: workflow_id, revision: workflow[:current_revision])
      @storage.transition_workflow_state(id: workflow_id, from: :failed, to: :pending)
      call(workflow_id)
    end

    private

    def transition_to_running(workflow_id)
      workflow = @storage.load_workflow(id: workflow_id)
      from = workflow[:state]
      unless %i[pending waiting paused].include?(from)
        raise StaleStateError, "workflow #{workflow_id} cannot transition from #{from.inspect} to :running"
      end
      @storage.transition_workflow_state(id: workflow_id, from: from, to: :running)
      workflow
    end

    def append_workflow_started_once(workflow_id, revision, workflow)
      events = @storage.read_events(workflow_id: workflow_id)
      return if events.any? { |e| e.type == :workflow_started }

      append_event(workflow_id, revision,
        type: :workflow_started,
        payload: {initial_context: workflow[:initial_context]})
    end

    def eligible_nodes(workflow_id, revision, definition)
      states = @storage.load_node_states(workflow_id: workflow_id, revision: revision)
      definition.topological_order.select do |node_id|
        states[node_id] == :pending && definition.predecessors(node_id).all? { |pred| states[pred] == :committed }
      end
    end

    def execute_node(workflow_id, revision, definition, node_id, runtime_profile)
      attempt_id = @storage.begin_attempt(
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        expected_node_state: :pending
      )
      attempt_number = attempt_number_from(attempt_id)

      append_event(workflow_id, revision,
        type: :node_started,
        node_id: node_id,
        attempt_id: attempt_id,
        payload: {attempt_number: attempt_number})

      input = build_step_input(workflow_id, revision, definition, node_id, attempt_number)
      result = safe_call_step(definition, node_id, input)

      handle_outcome(workflow_id, revision, definition, node_id, attempt_id, attempt_number, result, runtime_profile)
    end

    def handle_outcome(workflow_id, revision, definition, node_id, attempt_id, attempt_number, result, runtime_profile)
      case result
      when DAG::Success
        finished_ms = @clock.now_ms
        @storage.commit_attempt(attempt_id: attempt_id, result: result, node_state: :committed, finished_at_ms: finished_ms)
        append_event(workflow_id, revision,
          type: :node_committed,
          node_id: node_id,
          attempt_id: attempt_id,
          payload: {attempt_number: attempt_number})

        if result.proposed_mutations.any?
          @storage.transition_workflow_state(id: workflow_id, from: :running, to: :paused)
          append_event(workflow_id, revision,
            type: :workflow_paused,
            payload: {by_node: node_id, mutation_count: result.proposed_mutations.size})
          return :paused
        end
        :continue

      when DAG::Waiting
        finished_ms = @clock.now_ms
        @storage.commit_attempt(attempt_id: attempt_id, result: result, node_state: :waiting, finished_at_ms: finished_ms)
        append_event(workflow_id, revision,
          type: :node_waiting,
          node_id: node_id,
          attempt_id: attempt_id,
          payload: {reason: result.reason, not_before_ms: result.not_before_ms})
        :continue

      when DAG::Failure
        finished_ms = @clock.now_ms
        if result.retriable && attempt_number < runtime_profile.max_attempts_per_node
          @storage.commit_attempt(attempt_id: attempt_id, result: result, node_state: :pending, finished_at_ms: finished_ms)
          append_event(workflow_id, revision,
            type: :node_failed,
            node_id: node_id,
            attempt_id: attempt_id,
            payload: {retriable: true, attempt_number: attempt_number, error: result.error})
          return :continue
        end

        @storage.commit_attempt(attempt_id: attempt_id, result: result, node_state: :failed, finished_at_ms: finished_ms)
        append_event(workflow_id, revision,
          type: :node_failed,
          node_id: node_id,
          attempt_id: attempt_id,
          payload: {retriable: false, attempt_number: attempt_number, error: result.error})
        @storage.transition_workflow_state(id: workflow_id, from: :running, to: :failed)
        append_event(workflow_id, revision,
          type: :workflow_failed,
          payload: {failed_node: node_id, error: result.error})
        :failed_terminal
      end
    end

    def build_step_input(workflow_id, revision, definition, node_id, attempt_number)
      context = effective_context(workflow_id, revision, definition, node_id)
      DAG::StepInput[
        context: context,
        node_id: node_id,
        attempt_number: attempt_number,
        metadata: {workflow_id: workflow_id, revision: revision}
      ]
    end

    def effective_context(workflow_id, revision, definition, node_id)
      workflow = @storage.load_workflow(id: workflow_id)
      ctx = DAG::ExecutionContext.from(workflow[:initial_context])

      ordered_predecessors = definition.predecessors(node_id).to_a.sort_by(&:to_s)
      ordered_predecessors.each do |pred|
        attempts = @storage.list_attempts(workflow_id: workflow_id, revision: revision, node_id: pred)
        committed = attempts.reverse.find { |a| a[:state] == :committed }
        next unless committed

        patch = committed[:result].context_patch
        ctx = ctx.merge(patch) if patch && !patch.empty?
      end
      ctx
    end

    def safe_call_step(definition, node_id, input)
      step_def = definition.step_type_for(node_id)
      entry = @registry.lookup(step_def[:type])
      step = entry.klass.new(config: step_def[:config])
      result = step.call(input)
      unless DAG::StepProtocol.valid_result?(result)
        return DAG::Failure[
          error: {code: :step_bad_return, message: "expected Success/Waiting/Failure, got #{result.class}"},
          retriable: false
        ]
      end
      result
    rescue => e
      DAG::Failure[
        error: {code: :step_raised, class: e.class.name, message: e.message},
        retriable: false
      ]
    end

    def finalize(workflow_id, revision, paused:, failed:)
      return build_run_result(workflow_id, revision, :paused) if paused
      return build_run_result(workflow_id, revision, :failed) if failed

      states = @storage.load_node_states(workflow_id: workflow_id, revision: revision)
      final, terminal_event = resolve_terminal(states.values)

      @storage.transition_workflow_state(id: workflow_id, from: :running, to: final)
      append_event(workflow_id, revision, type: terminal_event, payload: {})
      build_run_result(workflow_id, revision, final)
    end

    # The loop only exits with paused/failed (handled by early returns above)
    # or with no eligible nodes left. In the latter case every node is either
    # :committed/:invalidated (workflow done) or :waiting (workflow waiting).
    # Any other shape would be a contract violation.
    def resolve_terminal(node_states)
      if node_states.all? { |s| s == :committed || s == :invalidated }
        [:completed, :workflow_completed]
      else
        [:waiting, :workflow_waiting]
      end
    end

    def build_run_result(workflow_id, revision, state)
      events = @storage.read_events(workflow_id: workflow_id)
      last_seq = events.last&.seq
      DAG::RunResult.new(
        state: state,
        last_event_seq: last_seq,
        outcome: {workflow_id: workflow_id, revision: revision},
        metadata: {}
      )
    end

    def append_event(workflow_id, revision, type:, payload:, node_id: nil, attempt_id: nil)
      event = DAG::Event[
        type: type,
        workflow_id: workflow_id,
        revision: revision,
        at_ms: @clock.now_ms,
        node_id: node_id,
        attempt_id: attempt_id,
        payload: payload
      ]
      stamped = @storage.append_event(workflow_id: workflow_id, event: event)
      @event_bus.publish(stamped)
    end

    def attempt_number_from(attempt_id)
      attempt_id.split("/").last.to_i
    end
  end
end
