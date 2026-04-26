# frozen_string_literal: true

module DAG
  REQUIRED_RUNNER_DEPENDENCIES = %i[storage event_bus registry clock id_generator fingerprint serializer].freeze

  class Runner
    RunContext = Data.define(
      :workflow_id,
      :revision,
      :definition,
      :runtime_profile,
      :base_context,
      :predecessors_by_node
    )

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
      append_workflow_started_once(run)

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
      workflow
    end

    def build_run_context(workflow_id, workflow)
      definition = @storage.load_current_definition(id: workflow_id)
      predecessors_by_node = {}
      definition.each_node do |node_id|
        preds = []
        definition.each_predecessor(node_id) { |p| preds << p }
        predecessors_by_node[node_id] = preds.sort!.freeze
      end
      predecessors_by_node.freeze

      RunContext.new(
        workflow_id: workflow_id,
        revision: definition.revision,
        definition: definition,
        runtime_profile: workflow[:runtime_profile],
        base_context: DAG::ExecutionContext.from(workflow[:initial_context]),
        predecessors_by_node: predecessors_by_node
      )
    end

    # Emitted once per workflow lifetime; survives Runner#retry_workflow.
    def append_workflow_started_once(run)
      first_event = @storage.read_events(workflow_id: run.workflow_id, limit: 1).first
      return if first_event&.type == :workflow_started

      append_event(run,
        type: :workflow_started,
        payload: {initial_context: run.base_context.to_h})
    end

    def eligible_nodes(run)
      states = @storage.load_node_states(workflow_id: run.workflow_id, revision: run.revision)
      run.definition.topological_order.select do |node_id|
        states[node_id] == :pending && run.predecessors_by_node[node_id].all? { |pred| states[pred] == :committed }
      end
    end

    def execute_node(run, node_id)
      attempt_number = @storage.count_attempts(
        workflow_id: run.workflow_id,
        revision: run.revision,
        node_id: node_id
      ) + 1

      attempt_id = @storage.begin_attempt(
        workflow_id: run.workflow_id,
        revision: run.revision,
        node_id: node_id,
        attempt_number: attempt_number,
        expected_node_state: :pending
      )

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
      event = build_event(run,
        type: event_type,
        node_id: node_id,
        attempt_id: attempt_id,
        payload: extra_payload.merge(attempt_number: attempt_number))
      outcome = @storage.commit_attempt(
        attempt_id: attempt_id,
        result: result,
        node_state: node_state,
        event: event,
        finished_at_ms: @clock.now_ms
      )
      @event_bus.publish(outcome[:event])
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
      ctx = run.base_context
      run.predecessors_by_node[node_id].each do |pred|
        committed = @storage.latest_committed_attempt(workflow_id: run.workflow_id, revision: run.revision, node_id: pred)
        next unless committed

        ctx = ctx.merge(committed[:result].context_patch)
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

    # The :paused/:failed_terminal early returns above are the only paths
    # back here that were caused by step outcomes; everything else fell
    # through naturally on `eligible.empty?`. The else branch is the
    # diagnostic case: not complete, no node waiting — surface :failed
    # explicitly rather than coerce to :waiting.
    def finalize(run, paused:, failed:)
      return build_run_result(run, :paused) if paused
      return build_run_result(run, :failed) if failed

      states = @storage.load_node_states(workflow_id: run.workflow_id, revision: run.revision).values

      if states.all? { |s| s == :committed || s == :invalidated }
        transition_and_emit_terminal(run, :completed, :workflow_completed, {})
      elsif states.any? { |s| s == :waiting }
        transition_and_emit_terminal(run, :waiting, :workflow_waiting, {})
      else
        transition_and_emit_terminal(run, :failed, :workflow_failed, {diagnostic: :no_eligible_but_incomplete})
      end
    end

    def transition_and_emit_terminal(run, state, event_type, payload)
      @storage.transition_workflow_state(id: run.workflow_id, from: :running, to: state)
      append_event(run, type: event_type, payload: payload)
      build_run_result(run, state)
    end

    def build_run_result(run, state)
      DAG::RunResult.new(
        state: state,
        last_event_seq: @storage.last_event_seq(workflow_id: run.workflow_id),
        outcome: {workflow_id: run.workflow_id, revision: run.revision},
        metadata: {}
      )
    end

    def build_event(run, type:, payload:, node_id: nil, attempt_id: nil)
      DAG::Event[
        type: type,
        workflow_id: run.workflow_id,
        revision: run.revision,
        at_ms: @clock.now_ms,
        node_id: node_id,
        attempt_id: attempt_id,
        payload: payload
      ]
    end

    def append_event(run, **kwargs)
      stamped = @storage.append_event(workflow_id: run.workflow_id, event: build_event(run, **kwargs))
      @event_bus.publish(stamped)
    end
  end
end
