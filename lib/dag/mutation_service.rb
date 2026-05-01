# frozen_string_literal: true

module DAG
  # Applies structural mutations to a workflow durably. Requires the
  # workflow to be in `:paused` or `:waiting`; mutating a `:running`
  # workflow raises {DAG::ConcurrentMutationError}.
  # @api public
  class MutationService
    # Workflow states from which mutations may be applied.
    MUTABLE_STATES = %i[paused waiting].freeze

    def initialize(storage:, event_bus:, clock:)
      missing = {storage:, event_bus:, clock:}.select { |_, v| v.nil? }.keys
      raise ArgumentError, "MutationService requires: #{missing.join(", ")}" unless missing.empty?

      @storage = storage
      @event_bus = event_bus
      @clock = clock
      @definition_editor = DAG::DefinitionEditor.new
      freeze
    end

    def apply(workflow_id:, mutation:, expected_revision:)
      workflow = @storage.load_workflow(id: workflow_id)
      guard_workflow_state!(workflow_id, workflow.fetch(:state))
      definition = @storage.load_current_definition(id: workflow_id)
      guard_expected_revision!(workflow_id, definition.revision, expected_revision)

      plan = @definition_editor.plan(definition, mutation)
      raise DAG::ValidationError, plan.reason unless plan.valid?

      new_revision = expected_revision + 1
      result = append_revision_with_state_guard(
        id: workflow_id,
        allowed_states: MUTABLE_STATES,
        parent_revision: expected_revision,
        definition: plan.new_definition,
        invalidated_node_ids: plan.invalidated_node_ids,
        event: mutation_event(workflow_id, mutation, expected_revision, new_revision, plan)
      )
      event = result[:event]
      @event_bus.publish(event) if event

      DAG::ApplyResult.new(
        workflow_id: workflow_id,
        revision: result.fetch(:revision),
        definition: plan.new_definition.with_revision(result.fetch(:revision)),
        invalidated_node_ids: plan.invalidated_node_ids,
        event: event
      )
    end

    private

    def append_revision_with_state_guard(id:, allowed_states:, parent_revision:, definition:, invalidated_node_ids:, event:)
      if storage_overrides?(:append_revision_if_workflow_state)
        return @storage.append_revision_if_workflow_state(
          id: id,
          allowed_states: allowed_states,
          parent_revision: parent_revision,
          definition: definition,
          invalidated_node_ids: invalidated_node_ids,
          event: event
        )
      end

      @storage.append_revision(
        id: id,
        parent_revision: parent_revision,
        definition: definition,
        invalidated_node_ids: invalidated_node_ids,
        event: event
      )
    end

    def storage_overrides?(method_name)
      return false unless @storage.respond_to?(method_name)

      @storage.method(method_name).owner != DAG::Ports::Storage
    end

    def guard_workflow_state!(workflow_id, state)
      case state
      when *MUTABLE_STATES then nil
      when :running
        raise DAG::ConcurrentMutationError, "workflow #{workflow_id} is running"
      else
        raise DAG::StaleStateError, "workflow #{workflow_id} cannot be mutated from #{state.inspect}"
      end
    end

    def guard_expected_revision!(workflow_id, current_revision, expected_revision)
      return if current_revision == expected_revision

      raise DAG::StaleRevisionError,
        "workflow #{workflow_id} current_revision is #{current_revision}, expected #{expected_revision}"
    end

    def mutation_event(workflow_id, mutation, parent_revision, new_revision, plan)
      DAG::Event[
        type: :mutation_applied,
        workflow_id: workflow_id,
        revision: new_revision,
        at_ms: @clock.now_ms,
        payload: {
          kind: mutation.kind,
          target_node_id: mutation.target_node_id.to_sym,
          parent_revision: parent_revision,
          revision: new_revision,
          invalidated_node_ids: plan.invalidated_node_ids
        }
      ]
    end
  end
end
