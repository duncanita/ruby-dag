# frozen_string_literal: true

module DAG
  module Adapters
    module Memory
      # Single-process in-memory implementation of `Ports::Storage`. Holds
      # workflow lifecycle, revisions, per-revision node states, attempts,
      # and an append-only event log inside a private `@state` hash.
      #
      # The class is a thin facade. All mutable bookkeeping lives in
      # `StorageState`, the only spot in `lib/dag/**` allowed to mutate hashes
      # in place. Every public method returns a deep-frozen deep-dup so the
      # internal hash never escapes the adapter.
      #
      # Single-process only. No thread, mutex, queue, file I/O, or
      # synchronization — concurrent processes must use a real durable
      # storage adapter. Public method signatures match `Ports::Storage`
      # exactly so the type-checker rejects callers passing the wrong
      # arguments.
      class Storage
        include Ports::Storage

        def initialize(initial_state: nil)
          @state = initial_state || StorageState.fresh_state
        end

        def create_workflow(id:, initial_definition:, initial_context:, runtime_profile:)
          dispatch(:create_workflow, {id: id, initial_definition: initial_definition, initial_context: initial_context, runtime_profile: runtime_profile})
        end

        def load_workflow(id:)
          dispatch(:load_workflow, {id: id})
        end

        def transition_workflow_state(id:, from:, to:)
          dispatch(:transition_workflow_state, {id: id, from: from, to: to})
        end

        def increment_workflow_retry(id:)
          dispatch(:increment_workflow_retry, {id: id})
        end

        def reset_failed_nodes(id:, revision:)
          dispatch(:reset_failed_nodes, {id: id, revision: revision})
        end

        def append_revision(id:, parent_revision:, definition:, invalidated_node_ids:, event:)
          dispatch(:append_revision, {id: id, parent_revision: parent_revision, definition: definition, invalidated_node_ids: invalidated_node_ids, event: event})
        end

        def load_revision(id:, revision:)
          dispatch(:load_revision, {id: id, revision: revision})
        end

        def load_current_definition(id:)
          dispatch(:load_current_definition, {id: id})
        end

        def load_node_states(workflow_id:, revision:)
          dispatch(:load_node_states, {workflow_id: workflow_id, revision: revision})
        end

        def transition_node_state(workflow_id:, revision:, node_id:, from:, to:)
          dispatch(:transition_node_state, {workflow_id: workflow_id, revision: revision, node_id: node_id, from: from, to: to})
        end

        def begin_attempt(workflow_id:, revision:, node_id:, attempt_number:, expected_node_state:)
          dispatch(:begin_attempt, {workflow_id: workflow_id, revision: revision, node_id: node_id, attempt_number: attempt_number, expected_node_state: expected_node_state})
        end

        def commit_attempt(attempt_id:, result:, node_state:, event:, finished_at_ms: nil)
          dispatch(:commit_attempt, {attempt_id: attempt_id, result: result, node_state: node_state, event: event, finished_at_ms: finished_at_ms})
        end

        def abort_running_attempts(workflow_id:)
          dispatch(:abort_running_attempts, {workflow_id: workflow_id})
        end

        def list_attempts(workflow_id:, revision: nil, node_id: nil)
          dispatch(:list_attempts, {workflow_id: workflow_id, revision: revision, node_id: node_id})
        end

        def count_attempts(workflow_id:, revision:, node_id:)
          dispatch(:count_attempts, {workflow_id: workflow_id, revision: revision, node_id: node_id})
        end

        def latest_committed_attempt(workflow_id:, revision:, node_id:)
          dispatch(:latest_committed_attempt, {workflow_id: workflow_id, revision: revision, node_id: node_id})
        end

        def append_event(workflow_id:, event:)
          dispatch(:append_event, {workflow_id: workflow_id, event: event})
        end

        def read_events(workflow_id:, after_seq: nil, limit: nil)
          dispatch(:read_events, {workflow_id: workflow_id, after_seq: after_seq, limit: limit})
        end

        def last_event_seq(workflow_id:)
          dispatch(:last_event_seq, {workflow_id: workflow_id})
        end

        private

        def dispatch(method_name, args)
          DAG.frozen_copy(StorageState.dispatch(@state, method_name, args))
        end
      end
    end
  end
end
