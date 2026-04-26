# frozen_string_literal: true

module DAG
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
      run = build_run_context(workflow_id, workflow)
      append_workflow_started_once(run, workflow[:state_before_call])

      paused = false
      failed = false
      loop do
        eligible = eligible_nodes(run)
        break if eligible.empty?

        eligible.each do |node_id|
          case execute_node(run, node_id)
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

      finalize(run, paused: paused, failed: failed)
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
      workflow.merge(state_before_call: from)
    end

    def build_run_context(workflow_id, workflow)
      definition = @storage.load_current_definition(id: workflow_id)
      predecessors_by_node = definition.nodes.each_with_object({}) do |node_id, acc|
        acc[node_id] = definition.predecessors(node_id).to_a.sort_by(&:to_s).freeze
      end.freeze

      RunContext.new(
        workflow_id: workflow_id,
        revision: definition.revision,
        definition: definition,
        runtime_profile: workflow[:runtime_profile],
        initial_context: workflow[:initial_context],
        predecessors_by_node: predecessors_by_node
      )
    end

    # First run iff transition came from :pending. Subsequent calls (resuming
    # from :waiting or :paused) skip the workflow_started event.
    def append_workflow_started_once(run, state_before_call)
      return unless state_before_call == :pending

      append_event(run,
        type: :workflow_started,
        payload: {initial_context: run.initial_context})
    end

    def eligible_nodes(run)
      states = @storage.load_node_states(workflow_id: run.workflow_id, revision: run.revision)
      run.definition.topological_order.select do |node_id|
        states[node_id] == :pending && run.predecessors_by_node[node_id].all? { |pred| states[pred] == :committed }
      end
    end

    def execute_node(run, node_id)
      attempt = @storage.begin_attempt(
        workflow_id: run.workflow_id,
        revision: run.revision,
        node_id: node_id,
        expected_node_state: :pending
      )
      attempt_id = attempt[:attempt_id]
      attempt_number = attempt[:attempt_number]

      append_event(run,
        type: :node_started,
        node_id: node_id,
        attempt_id: attempt_id,
        payload: {attempt_number: attempt_number})

      input = build_step_input(run, node_id, attempt_number)
      result = safe_call_step(run.definition, node_id, input)

      handle_outcome(run, node_id, attempt_id, attempt_number, result)
    end

    def handle_outcome(run, node_id, attempt_id, attempt_number, result)
      case result
      when DAG::Success
        commit_and_emit(run, node_id, attempt_id, attempt_number, result, :committed, :node_committed, {})
        return :continue if result.proposed_mutations.empty?

        @storage.transition_workflow_state(id: run.workflow_id, from: :running, to: :paused)
        append_event(run, type: :workflow_paused, payload: {by_node: node_id, mutation_count: result.proposed_mutations.size})
        :paused

      when DAG::Waiting
        commit_and_emit(run, node_id, attempt_id, attempt_number, result, :waiting, :node_waiting,
          {reason: result.reason, not_before_ms: result.not_before_ms})
        :continue

      when DAG::Failure
        if result.retriable && attempt_number < run.runtime_profile.max_attempts_per_node
          commit_and_emit(run, node_id, attempt_id, attempt_number, result, :pending, :node_failed,
            {retriable: true, error: result.error})
          return :continue
        end

        commit_and_emit(run, node_id, attempt_id, attempt_number, result, :failed, :node_failed,
          {retriable: false, error: result.error})
        @storage.transition_workflow_state(id: run.workflow_id, from: :running, to: :failed)
        append_event(run, type: :workflow_failed, payload: {failed_node: node_id, error: result.error})
        :failed_terminal
      end
    end

    def commit_and_emit(run, node_id, attempt_id, attempt_number, result, node_state, event_type, extra_payload)
      @storage.commit_attempt(
        attempt_id: attempt_id,
        result: result,
        node_state: node_state,
        finished_at_ms: @clock.now_ms
      )
      append_event(run,
        type: event_type,
        node_id: node_id,
        attempt_id: attempt_id,
        payload: extra_payload.merge(attempt_number: attempt_number))
    end

    def build_step_input(run, node_id, attempt_number)
      DAG::StepInput[
        context: effective_context(run, node_id),
        node_id: node_id,
        attempt_number: attempt_number,
        metadata: {workflow_id: run.workflow_id, revision: run.revision}
      ]
    end

    def effective_context(run, node_id)
      ctx = DAG::ExecutionContext.from(run.initial_context)
      run.predecessors_by_node[node_id].each do |pred|
        attempts = @storage.list_attempts(workflow_id: run.workflow_id, revision: run.revision, node_id: pred)
        committed = attempts.reverse.find { |a| a[:state] == :committed }
        next unless committed

        patch = committed[:result].context_patch
        ctx = ctx.merge(patch)
      end
      ctx
    end

    def safe_call_step(definition, node_id, input)
      step_def = definition.step_type_for(node_id)
      entry = @registry.lookup(step_def[:type])
      step = entry.klass.new(config: step_def[:config])
      result = step.call(input)
      return result if DAG::StepProtocol.valid_result?(result)

      DAG::Failure[
        error: {code: :step_bad_return, message: "expected Success/Waiting/Failure, got #{result.class}"},
        retriable: false
      ]
    rescue => e
      DAG::Result.exception_failure(:step_raised, e)
    end

    def finalize(run, paused:, failed:)
      return build_run_result(run, :paused) if paused
      return build_run_result(run, :failed) if failed

      states = @storage.load_node_states(workflow_id: run.workflow_id, revision: run.revision)
      final, terminal_event = resolve_terminal(states.values)

      @storage.transition_workflow_state(id: run.workflow_id, from: :running, to: final)
      append_event(run, type: terminal_event, payload: {})
      build_run_result(run, final)
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

    def build_run_result(run, state)
      events = @storage.read_events(workflow_id: run.workflow_id)
      DAG::RunResult.new(
        state: state,
        last_event_seq: events.last&.seq,
        outcome: {workflow_id: run.workflow_id, revision: run.revision},
        metadata: {}
      )
    end

    def append_event(run, type:, payload:, node_id: nil, attempt_id: nil)
      event = DAG::Event[
        type: type,
        workflow_id: run.workflow_id,
        revision: run.revision,
        at_ms: @clock.now_ms,
        node_id: node_id,
        attempt_id: attempt_id,
        payload: payload
      ]
      stamped = @storage.append_event(workflow_id: run.workflow_id, event: event)
      @event_bus.publish(stamped)
    end
  end
end
