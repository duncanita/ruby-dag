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
      # storage adapter.
      class Storage
        include Ports::Storage

        WORKFLOW_STATES = %i[pending running waiting paused completed failed].freeze
        NODE_STATES = %i[pending running committed waiting failed invalidated].freeze
        ATTEMPT_STATES = %i[running committed waiting failed aborted].freeze

        def initialize(initial_state: nil)
          @state = initial_state || StorageState.fresh_state
        end

        def create_workflow(**args) = dispatch(:create_workflow, args)
        def load_workflow(**args) = dispatch(:load_workflow, args)
        def transition_workflow_state(**args) = dispatch(:transition_workflow_state, args)
        def increment_workflow_retry(**args) = dispatch(:increment_workflow_retry, args)
        def reset_failed_nodes(**args) = dispatch(:reset_failed_nodes, args)
        def append_revision(**args) = dispatch(:append_revision, args)
        def load_revision(**args) = dispatch(:load_revision, args)
        def load_current_definition(**args) = dispatch(:load_current_definition, args)
        def load_node_states(**args) = dispatch(:load_node_states, args)
        def transition_node_state(**args) = dispatch(:transition_node_state, args)
        def begin_attempt(**args) = dispatch(:begin_attempt, args)
        def commit_attempt(**args) = dispatch(:commit_attempt, args)
        def abort_running_attempts(**args) = dispatch(:abort_running_attempts, args)
        def list_attempts(**args) = dispatch(:list_attempts, args)
        def count_attempts(**args) = dispatch(:count_attempts, args)
        def append_event(**args) = dispatch(:append_event, args)
        def read_events(**args) = dispatch(:read_events, args)

        private

        def dispatch(method_name, args)
          result = StorageState.dispatch(@state, method_name, args)
          DAG.deep_freeze(DAG.deep_dup(result))
        end
      end
    end
  end
end
