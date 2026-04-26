# frozen_string_literal: true

module DAG
  class MutationService
    ApplyResult = Data.define(:workflow_id, :revision, :definition, :invalidated_node_ids, :event) do
      def initialize(workflow_id:, revision:, definition:, invalidated_node_ids:, event:)
        super(
          workflow_id: workflow_id,
          revision: revision,
          definition: definition,
          invalidated_node_ids: DAG.deep_freeze(invalidated_node_ids.map(&:to_sym).sort_by(&:to_s)),
          event: event
        )
      end
    end

    def initialize(storage:, event_bus:, clock:, definition_editor: DAG::DefinitionEditor.new)
      missing = {storage: storage, event_bus: event_bus, clock: clock, definition_editor: definition_editor}
        .select { |_, value| value.nil? }.keys
      raise ArgumentError, "MutationService requires: #{missing.join(", ")}" unless missing.empty?

      @storage = storage
      @event_bus = event_bus
      @clock = clock
      @definition_editor = definition_editor
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
      result = @storage.append_revision(
        id: workflow_id,
        parent_revision: expected_revision,
        definition: plan.new_definition,
        invalidated_node_ids: plan.invalidated_node_ids,
        event: mutation_event(workflow_id, mutation, expected_revision, new_revision, plan)
      )
      event = result[:event]
      @event_bus.publish(event) if event

      ApplyResult.new(
        workflow_id: workflow_id,
        revision: result.fetch(:revision),
        definition: @storage.load_current_definition(id: workflow_id),
        invalidated_node_ids: plan.invalidated_node_ids,
        event: event
      )
    end

    private

    def guard_workflow_state!(workflow_id, state)
      raise DAG::ConcurrentMutationError, "workflow #{workflow_id} is running" if state == :running
      return if state == :paused || state == :waiting

      raise DAG::StaleStateError, "workflow #{workflow_id} cannot be mutated from #{state.inspect}"
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
