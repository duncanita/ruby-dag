# frozen_string_literal: true

module DAG
  # The seven keyword arguments required by `Runner.new`.
  REQUIRED_RUNNER_DEPENDENCIES = %i[storage event_bus registry clock id_generator fingerprint serializer].freeze

  # Frozen, dependency-injected execution kernel. The Runner runs the
  # layered algorithm from Roadmap v3.4 §R1 against the seven injected
  # ports; it never holds mutable state and never spawns threads.
  #
  # @api public
  class Runner
    # Workflow states from which `#call` is allowed.
    CALL_FROM_STATES = %i[pending].freeze

    # Workflow states from which `#resume` is allowed.
    RESUME_FROM_STATES = %i[running waiting paused].freeze

    # Internal carrier for per-call run context.
    # @api private
    RunContext = Data.define(
      :workflow_id,
      :revision,
      :definition,
      :runtime_profile,
      :base_context,
      :predecessors_by_node
    )

    # @return [Object] injected port (see {Ports::Storage})
    attr_reader :storage
    # @return [Object] injected port (see {Ports::EventBus})
    attr_reader :event_bus
    # @return [DAG::StepTypeRegistry]
    attr_reader :registry
    # @return [Object] injected port (see {Ports::Clock})
    attr_reader :clock
    # @return [Object] injected port (see {Ports::IdGenerator})
    attr_reader :id_generator
    # @return [Object] injected port (see {Ports::Fingerprint})
    attr_reader :fingerprint
    # @return [Object] injected port (see {Ports::Serializer})
    attr_reader :serializer

    # @param storage [Object] adapter implementing `Ports::Storage`
    # @param event_bus [Object] adapter implementing `Ports::EventBus`
    # @param registry [DAG::StepTypeRegistry] frozen registry of step types
    # @param clock [Object] adapter implementing `Ports::Clock`
    # @param id_generator [Object] adapter implementing `Ports::IdGenerator`
    # @param fingerprint [Object] adapter implementing `Ports::Fingerprint`
    # @param serializer [Object] adapter implementing `Ports::Serializer`
    # @raise [ArgumentError] when any keyword is missing or `nil`
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

    # Run a `:pending` workflow to a terminal state.
    # @param workflow_id [String]
    # @return [DAG::RunResult]
    # @raise [DAG::StaleStateError] when the workflow is not in `:pending`
    def call(workflow_id)
      workflow = acquire_running(workflow_id, allowed_from: CALL_FROM_STATES)
      run_workflow(workflow_id, workflow)
    end

    # Resume a `:running` (crashed), `:waiting`, or `:paused` workflow.
    # Aborts in-flight attempts before recomputing eligibility.
    # @param workflow_id [String]
    # @return [DAG::RunResult]
    # @raise [DAG::StaleStateError] when the workflow is not resumable
    def resume(workflow_id)
      workflow = acquire_running(workflow_id, allowed_from: RESUME_FROM_STATES)
      @storage.abort_running_attempts(workflow_id: workflow_id)
      run_workflow(workflow_id, workflow)
    end

    # Reset `:failed` nodes for the workflow's current revision and run
    # the workflow again; subject to `runtime_profile.max_workflow_retries`.
    # @param workflow_id [String]
    # @return [DAG::RunResult]
    # @raise [DAG::StaleStateError] when the workflow is not `:failed`
    # @raise [DAG::WorkflowRetryExhaustedError] when the budget is spent
    def retry_workflow(workflow_id)
      @storage.prepare_workflow_retry(id: workflow_id, from: :failed, to: :pending)
      call(workflow_id)
    end

    private

    def run_workflow(workflow_id, workflow)
      run = build_run_context(workflow_id, workflow)
      append_workflow_started_once(run)

      paused = false
      failed = false
      loop do
        eligible = eligible_nodes(run)
        break if eligible.empty?

        eligible.each do |node_id, current_state|
          case execute_node(run, node_id, current_state)
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

    def acquire_running(workflow_id, allowed_from:)
      workflow = @storage.load_workflow(id: workflow_id)
      from = workflow[:state]
      unless allowed_from.include?(from)
        raise StaleStateError,
          "workflow #{workflow_id} cannot transition to :running from #{from.inspect} (allowed: #{allowed_from.inspect})"
      end
      return workflow if from == :running

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

    ELIGIBLE_NODE_STATES = %i[pending invalidated].freeze
    private_constant :ELIGIBLE_NODE_STATES

    def eligible_nodes(run)
      states = @storage.load_node_states(workflow_id: run.workflow_id, revision: run.revision)
      run.definition.topological_order.filter_map do |node_id|
        current = states[node_id]
        next unless ELIGIBLE_NODE_STATES.include?(current)
        next unless run.predecessors_by_node[node_id].all? { |pred| states[pred] == :committed }

        [node_id, current]
      end
    end

    def execute_node(run, node_id, current_state)
      attempt_number = @storage.count_attempts(
        workflow_id: run.workflow_id,
        revision: run.revision,
        node_id: node_id
      ) + 1

      attempt_id = @storage.begin_attempt(
        workflow_id: run.workflow_id,
        revision: run.revision,
        node_id: node_id,
        expected_node_state: current_state,
        attempt_number: attempt_number
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

        atomic_transition_with_event(
          run,
          from: :running,
          to: :paused,
          event_type: :workflow_paused,
          payload: {by_node: node_id, mutation_count: result.proposed_mutations.size}
        )
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
        atomic_transition_with_event(
          run,
          from: :running,
          to: :failed,
          event_type: :workflow_failed,
          payload: {failed_node: node_id, error: result.error}
        )
        :failed_terminal
      end
    end

    def commit_and_emit(run, node_id, attempt_id, attempt_number, result, node_state, event_type, extra_payload)
      now_ms = @clock.now_ms
      prepared_effects = prepare_effects(
        run,
        node_id: node_id,
        attempt_id: attempt_id,
        result: result,
        created_at_ms: now_ms
      )
      payload = extra_payload
        .merge(attempt_number: attempt_number)
        .merge(effect_event_payload(event_type, prepared_effects))
      event = build_event(run,
        type: event_type,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: now_ms,
        payload: payload)
      stamped = @storage.commit_attempt(
        attempt_id: attempt_id,
        result: result,
        node_state: node_state,
        event: event,
        effects: prepared_effects
      )
      @event_bus.publish(stamped)
    end

    def build_step_input(run, node_id, attempt_number)
      DAG::StepInput[
        context: effective_context(run, node_id),
        node_id: node_id,
        attempt_number: attempt_number,
        metadata: {
          workflow_id: run.workflow_id,
          revision: run.revision,
          effects: effects_snapshot_for(run, node_id)
        }
      ]
    end

    EMPTY_EFFECTS = [].freeze
    private_constant :EMPTY_EFFECTS

    def prepare_effects(run, node_id:, attempt_id:, result:, created_at_ms:)
      return EMPTY_EFFECTS unless result.respond_to?(:proposed_effects)
      return EMPTY_EFFECTS if result.proposed_effects.empty?

      blocking = result.is_a?(DAG::Waiting)
      result.proposed_effects.map do |intent|
        DAG::Effects::PreparedIntent.from_intent(
          intent: intent,
          workflow_id: run.workflow_id,
          revision: run.revision,
          node_id: node_id,
          attempt_id: attempt_id,
          payload_fingerprint: @fingerprint.compute(intent.payload),
          blocking: blocking,
          created_at_ms: created_at_ms
        )
      end.freeze
    end

    def effect_event_payload(event_type, prepared_effects)
      return {} unless event_type == :node_waiting

      {
        effect_refs: prepared_effects.map(&:ref),
        effect_count: prepared_effects.size
      }
    end

    EFFECT_SNAPSHOT_FIELDS = %i[
      id
      ref
      type
      key
      payload
      payload_fingerprint
      blocking
      status
      result
      error
      external_ref
      not_before_ms
      metadata
    ].freeze
    private_constant :EFFECT_SNAPSHOT_FIELDS

    def effects_snapshot_for(run, node_id)
      records = @storage.list_effects_for_node(
        workflow_id: run.workflow_id,
        revision: run.revision,
        node_id: node_id
      )

      records
        .sort_by(&:ref)
        .each_with_object({}) do |record, snapshot|
          snapshot[record.ref] = effect_snapshot(record)
        end
    end

    def effect_snapshot(record)
      EFFECT_SNAPSHOT_FIELDS.each_with_object({}) do |field, snapshot|
        snapshot[field] = record.public_send(field)
      end
    end

    def effective_context(run, node_id)
      ctx = run.base_context
      run.predecessors_by_node[node_id].each do |pred|
        attempts = @storage.list_attempts(workflow_id: run.workflow_id, revision: run.revision, node_id: pred)
        committed = canonical_committed_attempt(attempts)
        next unless committed

        ctx = ctx.merge(committed[:result].context_patch)
      end
      ctx
    end

    # Pick the canonical committed attempt independent of `list_attempts`
    # ordering: highest `attempt_number`, with `attempt_id.to_s` ASCII as
    # a defensive tie-break. Single-pass; avoids the intermediate Array
    # and per-element key Array that `select`/`max_by` would allocate on
    # this hot path.
    def canonical_committed_attempt(attempts)
      best = nil
      best_id = nil
      attempts.each do |a|
        next unless a[:state] == :committed
        n = a.fetch(:attempt_number)
        if best.nil? || n > best.fetch(:attempt_number)
          best = a
          best_id = nil
        elsif n == best.fetch(:attempt_number)
          best_id ||= best.fetch(:attempt_id).to_s
          candidate_id = a.fetch(:attempt_id).to_s
          if candidate_id > best_id
            best = a
            best_id = candidate_id
          end
        end
      end
      best
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

      if states.all? { |s| s == :committed }
        transition_and_emit_terminal(run, :completed, :workflow_completed, {})
      elsif states.any? { |s| s == :waiting }
        transition_and_emit_terminal(run, :waiting, :workflow_waiting, {})
      else
        transition_and_emit_terminal(run, :failed, :workflow_failed, {diagnostic: :no_eligible_but_incomplete})
      end
    end

    def transition_and_emit_terminal(run, state, event_type, payload)
      atomic_transition_with_event(run, from: :running, to: state, event_type: event_type, payload: payload)
      build_run_result(run, state)
    end

    # Atomic at the storage layer: the row transition and the event append
    # cannot diverge under crash. The event_bus publish happens after the
    # storage call returns and is best-effort (non-durable).
    def atomic_transition_with_event(run, from:, to:, event_type:, payload:)
      event = build_event(run, type: event_type, payload: payload)
      result = @storage.transition_workflow_state(id: run.workflow_id, from: from, to: to, event: event)
      stamped = result.is_a?(Hash) ? result[:event] : nil
      @event_bus.publish(stamped) if stamped
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

    def build_event(run, type:, payload:, node_id: nil, attempt_id: nil, at_ms: nil)
      DAG::Event[
        type: type,
        workflow_id: run.workflow_id,
        revision: run.revision,
        at_ms: at_ms || @clock.now_ms,
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
