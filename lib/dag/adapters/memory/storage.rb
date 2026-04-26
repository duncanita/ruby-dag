# frozen_string_literal: true

module DAG
  module Adapters
    module Memory
      # Single-process in-memory implementation of `Ports::Storage`. Mutable
      # bookkeeping lives in `StorageState`; this facade enforces port-shape
      # kwargs and deep-freezes every return value.
      class Storage
        include Ports::Storage

        def initialize(initial_state: nil)
          @state = initial_state || StorageState.fresh_state
        end

        def create_workflow(id:, initial_definition:, initial_context:, runtime_profile:)
          frozen StorageState.create_workflow(@state, id: id, initial_definition: initial_definition, initial_context: initial_context, runtime_profile: runtime_profile)
        end

        def load_workflow(id:)
          frozen StorageState.load_workflow(@state, id: id)
        end

        def transition_workflow_state(id:, from:, to:)
          frozen StorageState.transition_workflow_state(@state, id: id, from: from, to: to)
        end

        def append_revision(id:, parent_revision:, definition:, invalidated_node_ids:, event:)
          frozen StorageState.append_revision(@state, id: id, parent_revision: parent_revision, definition: definition, invalidated_node_ids: invalidated_node_ids, event: event)
        end

        def load_revision(id:, revision:)
          frozen StorageState.load_revision(@state, id: id, revision: revision)
        end

        def load_current_definition(id:)
          frozen StorageState.load_current_definition(@state, id: id)
        end

        def load_node_states(workflow_id:, revision:)
          frozen StorageState.load_node_states(@state, workflow_id: workflow_id, revision: revision)
        end

        def transition_node_state(workflow_id:, revision:, node_id:, from:, to:)
          frozen StorageState.transition_node_state(@state, workflow_id: workflow_id, revision: revision, node_id: node_id, from: from, to: to)
        end

        def begin_attempt(workflow_id:, revision:, node_id:, expected_node_state:)
          frozen StorageState.begin_attempt(@state, workflow_id: workflow_id, revision: revision, node_id: node_id, expected_node_state: expected_node_state)
        end

        def commit_attempt(attempt_id:, result:, node_state:, event:)
          frozen StorageState.commit_attempt(@state, attempt_id: attempt_id, result: result, node_state: node_state, event: event)
        end

        def abort_running_attempts(workflow_id:)
          frozen StorageState.abort_running_attempts(@state, workflow_id: workflow_id)
        end

        def list_attempts(workflow_id:, revision: nil, node_id: nil)
          frozen StorageState.list_attempts(@state, workflow_id: workflow_id, revision: revision, node_id: node_id)
        end

        def count_attempts(workflow_id:, revision:, node_id:)
          frozen StorageState.count_attempts(@state, workflow_id: workflow_id, revision: revision, node_id: node_id)
        end

        def append_event(workflow_id:, event:)
          frozen StorageState.append_event(@state, workflow_id: workflow_id, event: event)
        end

        def read_events(workflow_id:, after_seq: nil, limit: nil)
          frozen StorageState.read_events(@state, workflow_id: workflow_id, after_seq: after_seq, limit: limit)
        end

        def prepare_workflow_retry(id:)
          frozen StorageState.prepare_workflow_retry(@state, id: id)
        end

        private

        def frozen(value) = DAG.frozen_copy(value)
      end
    end
  end
end
