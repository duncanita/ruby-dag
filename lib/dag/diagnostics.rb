# frozen_string_literal: true

module DAG
  # Kernel-generic diagnostic readers. All values are derived through the
  # storage port, not adapter internals, so callers get deterministic shapes
  # they can serialize or persist without carrying runtime/application objects.
  # @api public
  module Diagnostics
    module_function

    # @param storage [#read_events]
    # @param workflow_id [String]
    # @param after_seq [Integer, nil]
    # @param limit [Integer, nil]
    # @return [Array<DAG::TraceRecord>]
    def trace_records(storage:, workflow_id:, after_seq: nil, limit: nil)
      DAG::Validation.dependency!(storage, :read_events, "storage")
      DAG::Validation.string!(workflow_id, "workflow_id")
      DAG::Validation.optional_integer!(after_seq, "after_seq")
      DAG::Validation.optional_integer!(limit, "limit")

      storage.read_events(workflow_id: workflow_id, after_seq: after_seq, limit: limit)
        .map { |event| DAG::TraceRecord.from_event(event) }
    end

    # @param storage [#load_workflow, #load_node_states, #list_attempts, #list_effects_for_node]
    # @param workflow_id [String]
    # @param revision [Integer, nil]
    # @return [Array<DAG::NodeDiagnostic>]
    def node_diagnostics(storage:, workflow_id:, revision: nil)
      validate_node_diagnostic_storage!(storage)
      DAG::Validation.string!(workflow_id, "workflow_id")
      DAG::Validation.revision!(revision) unless revision.nil?

      resolved_revision = revision || storage.load_workflow(id: workflow_id).fetch(:current_revision)
      node_states = storage.load_node_states(workflow_id: workflow_id, revision: resolved_revision)

      node_states.keys.sort_by(&:to_s).map do |node_id|
        DAG::NodeDiagnostic.from_records(
          workflow_id: workflow_id,
          revision: resolved_revision,
          node_id: node_id,
          state: node_states.fetch(node_id),
          attempts: storage.list_attempts(workflow_id: workflow_id, revision: resolved_revision, node_id: node_id),
          effects: storage.list_effects_for_node(workflow_id: workflow_id, revision: resolved_revision, node_id: node_id)
        )
      end
    end

    def validate_node_diagnostic_storage!(storage)
      %i[load_workflow load_node_states list_attempts list_effects_for_node].each do |method_name|
        DAG::Validation.dependency!(storage, method_name, "storage")
      end
    end
    private_class_method :validate_node_diagnostic_storage!
  end
end
