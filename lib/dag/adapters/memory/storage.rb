# frozen_string_literal: true

module DAG
  module Adapters
    # Single-process in-memory adapters. Suitable for tests, scripts, and
    # examples; not safe for multi-process or multi-threaded use.
    # @api public
    module Memory
      # Single-process in-memory implementation of `Ports::Storage`. Mutable
      # bookkeeping lives in `StorageState`; this facade enforces port-shape
      # kwargs and deep-freezes every return value.
      # @api public
      class Storage
        include Ports::Storage

        # @param initial_state [Hash, nil] internal storage state, for
        #   testing/recovery only
        def initialize(initial_state: nil)
          @state = initial_state || StorageState.fresh_state
        end

        # (see Ports::Storage#create_workflow)
        def create_workflow(id:, initial_definition:, initial_context:, runtime_profile:)
          frozen StorageState.create_workflow(@state, id: id, initial_definition: initial_definition, initial_context: initial_context, runtime_profile: runtime_profile)
        end

        # (see Ports::Storage#load_workflow)
        def load_workflow(id:)
          frozen StorageState.load_workflow(@state, id: id)
        end

        # (see Ports::Storage#transition_workflow_state)
        def transition_workflow_state(id:, from:, to:, event: nil)
          frozen StorageState.transition_workflow_state(@state, id: id, from: from, to: to, event: event)
        end

        # (see Ports::Storage#append_revision)
        def append_revision(id:, parent_revision:, definition:, invalidated_node_ids:, event:)
          frozen StorageState.append_revision(@state, id: id, parent_revision: parent_revision, definition: definition, invalidated_node_ids: invalidated_node_ids, event: event)
        end

        # (see Ports::Storage#load_revision)
        def load_revision(id:, revision:)
          frozen StorageState.load_revision(@state, id: id, revision: revision)
        end

        # (see Ports::Storage#load_current_definition)
        def load_current_definition(id:)
          frozen StorageState.load_current_definition(@state, id: id)
        end

        # (see Ports::Storage#load_node_states)
        def load_node_states(workflow_id:, revision:)
          frozen StorageState.load_node_states(@state, workflow_id: workflow_id, revision: revision)
        end

        # (see Ports::Storage#transition_node_state)
        def transition_node_state(workflow_id:, revision:, node_id:, from:, to:)
          frozen StorageState.transition_node_state(@state, workflow_id: workflow_id, revision: revision, node_id: node_id, from: from, to: to)
        end

        # (see Ports::Storage#begin_attempt)
        def begin_attempt(workflow_id:, revision:, node_id:, expected_node_state:, attempt_number:)
          frozen StorageState.begin_attempt(
            @state,
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            expected_node_state: expected_node_state,
            attempt_number: attempt_number
          )
        end

        # (see Ports::Storage#commit_attempt)
        def commit_attempt(attempt_id:, result:, node_state:, event:)
          frozen StorageState.commit_attempt(@state, attempt_id: attempt_id, result: result, node_state: node_state, event: event)
        end

        # (see Ports::Storage#abort_running_attempts)
        def abort_running_attempts(workflow_id:)
          frozen StorageState.abort_running_attempts(@state, workflow_id: workflow_id)
        end

        # (see Ports::Storage#list_attempts)
        def list_attempts(workflow_id:, revision: nil, node_id: nil)
          frozen StorageState.list_attempts(@state, workflow_id: workflow_id, revision: revision, node_id: node_id)
        end

        # (see Ports::Storage#count_attempts)
        def count_attempts(workflow_id:, revision:, node_id:)
          frozen StorageState.count_attempts(@state, workflow_id: workflow_id, revision: revision, node_id: node_id)
        end

        # (see Ports::Storage#append_event)
        def append_event(workflow_id:, event:)
          frozen StorageState.append_event(@state, workflow_id: workflow_id, event: event)
        end

        # (see Ports::Storage#read_events)
        def read_events(workflow_id:, after_seq: nil, limit: nil)
          frozen StorageState.read_events(@state, workflow_id: workflow_id, after_seq: after_seq, limit: limit)
        end

        # (see Ports::Storage#prepare_workflow_retry)
        def prepare_workflow_retry(id:, from: :failed, to: :pending, event: nil)
          frozen StorageState.prepare_workflow_retry(@state, id: id, from: from, to: to, event: event)
        end

        private

        def frozen(value) = DAG.frozen_copy(value)
      end
    end
  end
end
