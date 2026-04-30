# frozen_string_literal: true

module DAG
  module Ports
    # Storage port — 15 documented methods (Roadmap v3.4 §C / Appendix I)
    # plus documented extensions needed by R1/R2 retry and resume semantics.
    #
    # Adapters persist workflow rows, definition revisions, node states,
    # attempts, and the durable event log. Every method that returns
    # storage-owned values must return a deep-frozen value or a fresh deep
    # dup; callers must not mutate adapter state through returned objects.
    #
    # @api public
    module Storage
      # Persist a fresh workflow in `:pending` with the supplied initial
      # definition (revision 1) and runtime profile.
      #
      # @param id [String] workflow id
      # @param initial_definition [DAG::Workflow::Definition] revision 1 graph
      # @param initial_context [Hash] JSON-safe context seed
      # @param runtime_profile [DAG::RuntimeProfile] frozen profile
      # @return [void]
      def create_workflow(id:, initial_definition:, initial_context:, runtime_profile:)
        raise PortNotImplementedError
      end

      # Load the workflow row keyed by `id`.
      #
      # @param id [String]
      # @return [Hash] keys: :id, :state, :workflow_retry_count, :runtime_profile, :initial_context
      # @raise [DAG::UnknownWorkflowError] when no workflow has the supplied id
      def load_workflow(id:)
        raise PortNotImplementedError
      end

      # Atomically transitions the workflow row from `from` to `to`, and if a
      # non-nil event is supplied, appends it durably in the same step. The
      # atomicity is required so that durable terminal state and its
      # corresponding terminal event cannot diverge under crash.
      #
      # @param id [String]
      # @param from [Symbol] expected current state
      # @param to [Symbol] target state
      # @param event [DAG::Event, nil] optional event to append in the same atomic step
      # @return [Hash] {id:, state:, event: stamped_event_or_nil}
      # @raise [DAG::StaleStateError] when the workflow is not in `from`
      def transition_workflow_state(id:, from:, to:, event: nil)
        raise PortNotImplementedError
      end

      # Atomically appends a definition revision, resets invalidated/new nodes
      # to :pending for the new revision, and appends the supplied durable
      # event when present.
      #
      # @param id [String]
      # @param parent_revision [Integer] expected current revision (CAS guard)
      # @param definition [DAG::Workflow::Definition] new revision graph
      # @param invalidated_node_ids [Array<Symbol>] nodes whose committed
      #   results should be discarded in the new revision
      # @param event [DAG::Event, nil] optional `mutation_applied` event
      # @return [Hash] {id:, revision:, event: stamped_event}
      # @raise [DAG::StaleRevisionError] when `parent_revision` no longer matches
      def append_revision(id:, parent_revision:, definition:, invalidated_node_ids:, event:)
        raise PortNotImplementedError
      end

      # Load a specific revision row.
      #
      # @param id [String]
      # @param revision [Integer]
      # @return [Hash]
      def load_revision(id:, revision:)
        raise PortNotImplementedError
      end

      # Load the workflow's current `Definition`.
      #
      # @param id [String]
      # @return [DAG::Workflow::Definition]
      def load_current_definition(id:)
        raise PortNotImplementedError
      end

      # Load every node's state for a given revision.
      #
      # @param workflow_id [String]
      # @param revision [Integer]
      # @return [Hash{Symbol => Symbol}] node_id => node state
      def load_node_states(workflow_id:, revision:)
        raise PortNotImplementedError
      end

      # CAS transition for a single node.
      #
      # @param workflow_id [String]
      # @param revision [Integer]
      # @param node_id [Symbol]
      # @param from [Symbol] expected current state
      # @param to [Symbol] target state
      # @return [void]
      # @raise [DAG::StaleStateError] when the node is not in `from`
      def transition_node_state(workflow_id:, revision:, node_id:, from:, to:)
        raise PortNotImplementedError
      end

      # The Runner owns attempt numbering and passes the already-computed
      # number here; adapters persist it and do not recalculate.
      #
      # @param workflow_id [String]
      # @param revision [Integer]
      # @param node_id [Symbol]
      # @param expected_node_state [Symbol] CAS guard for the node row
      # @param attempt_number [Integer] supplied by the Runner
      # @return [String] attempt id
      # @raise [DAG::StaleStateError] when the node row no longer matches
      def begin_attempt(workflow_id:, revision:, node_id:, expected_node_state:, attempt_number:)
        raise PortNotImplementedError
      end

      # One-shot atomic terminal transition for an attempt. Adapters must reject
      # commits for attempts that are no longer :running.
      #
      # @param attempt_id [String]
      # @param result [DAG::Success, DAG::Waiting, DAG::Failure]
      # @param node_state [Symbol] target node state after this commit
      # @param event [DAG::Event] durable event to append in the same step
      # @return [void]
      def commit_attempt(attempt_id:, result:, node_state:, event:)
        raise PortNotImplementedError
      end

      # Abort in-flight attempts for a workflow before resume. Adapters must
      # also reset any corresponding current-revision node still in :running
      # back to :pending so eligibility can recompute from committed state.
      #
      # @param workflow_id [String]
      # @return [void]
      def abort_running_attempts(workflow_id:)
        raise PortNotImplementedError
      end

      # List attempts, optionally filtered by revision and/or node.
      #
      # @param workflow_id [String]
      # @param revision [Integer, nil]
      # @param node_id [Symbol, nil]
      # @return [Array<Hash>]
      def list_attempts(workflow_id:, revision: nil, node_id: nil)
        raise PortNotImplementedError
      end

      # Count attempts for a node within a revision, excluding `:aborted`.
      #
      # @param workflow_id [String]
      # @param revision [Integer]
      # @param node_id [Symbol]
      # @return [Integer]
      def count_attempts(workflow_id:, revision:, node_id:)
        raise PortNotImplementedError
      end

      # Durably append an event to the workflow's append-only log. Returns the
      # stamped `Event` (with `seq`).
      #
      # @param workflow_id [String]
      # @param event [DAG::Event] event without a `seq`
      # @return [DAG::Event] event with a monotonic `seq` assigned
      def append_event(workflow_id:, event:)
        raise PortNotImplementedError
      end

      # Read the workflow event log, optionally filtered.
      #
      # @param workflow_id [String]
      # @param after_seq [Integer, nil] only return events with `seq > after_seq`
      # @param limit [Integer, nil] cap result size
      # @return [Array<DAG::Event>]
      def read_events(workflow_id:, after_seq: nil, limit: nil)
        raise PortNotImplementedError
      end

      # Port extension (see CLAUDE.md "Port extensions"). With a CAS guard on
      # workflow state and on the retry budget, atomically:
      # (a) find :failed nodes for the workflow's current revision,
      # (b) mark each corresponding :failed attempt as :aborted,
      # (c) transition those nodes back to :pending,
      # (d) increment the workflow's retry-count tracking,
      # (e) transition the workflow row from `from` to `to`,
      # (f) append the supplied durable event, when present.
      #
      # The retry-budget check (`workflow_retry_count < max_workflow_retries`)
      # lives inside the atomic boundary so concurrent retries cannot bypass
      # it via stale reads from outside the transaction.
      #
      # @param id [String]
      # @param from [Symbol] expected current workflow state
      # @param to [Symbol] target workflow state
      # @param event [DAG::Event, nil] optional event to append in the same atomic step
      # @raise [DAG::StaleStateError] when current state is not `from`
      # @raise [DAG::WorkflowRetryExhaustedError] when the retry budget is spent
      # @return [Hash] {id:, state:, reset:, workflow_retry_count:, event: stamped_event_or_nil}
      def prepare_workflow_retry(id:, from: :failed, to: :pending, event: nil)
        raise PortNotImplementedError
      end
    end
  end
end
