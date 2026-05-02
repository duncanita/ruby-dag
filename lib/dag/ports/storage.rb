# frozen_string_literal: true

module DAG
  module Ports
    # Storage port. `CONTRACT.md` and this module document the current
    # effect-aware shape, including the R1/R2 retry/resume extensions.
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
      # @return [Hash] {id:, current_revision:}
      def create_workflow(id:, initial_definition:, initial_context:, runtime_profile:)
        raise PortNotImplementedError
      end

      # Load the workflow row keyed by `id`.
      #
      # @param id [String]
      # @return [Hash] keys: :id, :state, :current_revision, :workflow_retry_count, :runtime_profile, :initial_context
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
      # @return [Hash] {id:, revision:, event: stamped_event_or_nil}
      # @raise [DAG::StaleRevisionError] when `parent_revision` no longer matches
      def append_revision(id:, parent_revision:, definition:, invalidated_node_ids:, event:)
        raise PortNotImplementedError
      end

      # Port extension: append a definition revision only if the workflow row
      # is still in one of `allowed_states`. This lets mutation services bind
      # the workflow-state guard and revision CAS inside one storage boundary.
      #
      # @param id [String]
      # @param allowed_states [Array<Symbol>] allowed current workflow states
      # @param parent_revision [Integer] expected current revision (CAS guard)
      # @param definition [DAG::Workflow::Definition] new revision graph
      # @param invalidated_node_ids [Array<Symbol>]
      # @param event [DAG::Event, nil]
      # @return [Hash] {id:, revision:, event: stamped_event_or_nil}
      # @raise [DAG::ConcurrentMutationError] when current state is :running
      # @raise [DAG::StaleStateError] when current state is not allowed
      # @raise [DAG::StaleRevisionError] when `parent_revision` no longer matches
      def append_revision_if_workflow_state(id:, allowed_states:, parent_revision:, definition:, invalidated_node_ids:, event:)
        raise PortNotImplementedError
      end

      # Load a specific revision definition.
      #
      # @param id [String]
      # @param revision [Integer]
      # @return [DAG::Workflow::Definition]
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
      # @return [Hash] {workflow_id:, revision:, node_id:, state:}
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
      # commits for attempts that are no longer :running. Effect-aware adapters
      # also persist/link `effects` in the same atomic step.
      #
      # @param attempt_id [String]
      # @param result [DAG::Success, DAG::Waiting, DAG::Failure]
      # @param node_state [Symbol] target node state after this commit
      # @param event [DAG::Event] durable event to append in the same step
      # @param effects [Array<DAG::Effects::PreparedIntent>] prepared effect intents to reserve/link
      # @return [DAG::Event] stamped event
      def commit_attempt(attempt_id:, result:, node_state:, event:, effects: [])
        raise PortNotImplementedError
      end

      # List durable effect snapshots linked to a workflow node in a revision.
      #
      # @param workflow_id [String]
      # @param revision [Integer]
      # @param node_id [Symbol]
      # @return [Array<DAG::Effects::Record>]
      def list_effects_for_node(workflow_id:, revision:, node_id:)
        raise PortNotImplementedError
      end

      # List durable effect snapshots linked to an attempt.
      #
      # @param attempt_id [String]
      # @return [Array<DAG::Effects::Record>]
      def list_effects_for_attempt(attempt_id:)
        raise PortNotImplementedError
      end

      # Atomically claim ready effect records by assigning a lease.
      #
      # @param limit [Integer] maximum number of records to claim
      # @param owner_id [String] dispatcher owner id
      # @param lease_ms [Integer] lease duration in milliseconds
      # @param now_ms [Integer] current wall-clock milliseconds
      # @return [Array<DAG::Effects::Record>] claimed records
      def claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:)
        raise PortNotImplementedError
      end

      # Mark a claimed effect as succeeded.
      #
      # @param effect_id [String]
      # @param owner_id [String] current lease owner
      # @param result [Object] JSON-safe result
      # @param external_ref [Object, nil] JSON-safe external reference
      # @param now_ms [Integer]
      # @return [DAG::Effects::Record] updated terminal record
      # @raise [DAG::Effects::UnknownEffectError] when `effect_id` is unknown
      # @raise [DAG::Effects::StaleLeaseError] when the lease is missing, expired, or owned by another dispatcher
      def mark_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:)
        raise PortNotImplementedError
      end

      # Mark a claimed effect as failed, either retriable or terminal.
      #
      # @param effect_id [String]
      # @param owner_id [String] current lease owner
      # @param error [Object] JSON-safe error
      # @param retriable [Boolean]
      # @param not_before_ms [Integer, nil] retry delay hint for retriable failures
      # @param now_ms [Integer]
      # @return [DAG::Effects::Record] updated failed record
      # @raise [DAG::Effects::UnknownEffectError] when `effect_id` is unknown
      # @raise [DAG::Effects::StaleLeaseError] when the lease is missing, expired, or owned by another dispatcher
      def mark_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
        raise PortNotImplementedError
      end

      # Port extension: atomically mark a claimed effect as succeeded and
      # release any waiting nodes that become satisfied by that terminal
      # effect state. This closes the crash window between a terminal mark and
      # a separate release call in durable adapters.
      #
      # @param effect_id [String]
      # @param owner_id [String] current lease owner
      # @param result [Object] JSON-safe result
      # @param external_ref [Object, nil] JSON-safe external reference
      # @param now_ms [Integer]
      # @return [Hash] {record: DAG::Effects::Record, released: Array<Hash>}
      #   Each release receipt is shaped as
      #   {workflow_id:, revision:, node_id:, attempt_id:, released_at_ms:}.
      # @raise [DAG::Effects::UnknownEffectError] when `effect_id` is unknown
      # @raise [DAG::Effects::StaleLeaseError] when the lease is missing, expired, or owned by another dispatcher
      def complete_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:)
        raise PortNotImplementedError
      end

      # Port extension: atomically mark a claimed effect as failed and release
      # waiting nodes when the resulting failure is terminal.
      #
      # @param effect_id [String]
      # @param owner_id [String] current lease owner
      # @param error [Object] JSON-safe error
      # @param retriable [Boolean]
      # @param not_before_ms [Integer, nil] retry delay hint for retriable failures
      # @param now_ms [Integer]
      # @return [Hash] {record: DAG::Effects::Record, released: Array<Hash>}
      #   Each release receipt is shaped as
      #   {workflow_id:, revision:, node_id:, attempt_id:, released_at_ms:}.
      # @raise [DAG::Effects::UnknownEffectError] when `effect_id` is unknown
      # @raise [DAG::Effects::StaleLeaseError] when the lease is missing, expired, or owned by another dispatcher
      def complete_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
        raise PortNotImplementedError
      end

      # Reset waiting nodes linked to `effect_id` once all blocking effects for
      # the waiting attempt are terminal. The node is reset to :pending; the
      # waiting attempt remains waiting as durable history.
      #
      # @param effect_id [String]
      # @param now_ms [Integer]
      # @return [Array<Hash>] release receipts shaped as
      #   {workflow_id:, revision:, node_id:, attempt_id:, released_at_ms:}
      # @raise [DAG::Effects::UnknownEffectError] when `effect_id` is unknown
      def release_nodes_satisfied_by_effect(effect_id:, now_ms:)
        raise PortNotImplementedError
      end

      # Abort in-flight attempts for a workflow before resume. Adapters must
      # also reset any corresponding current-revision node still in :running
      # back to :pending so eligibility can recompute from committed state.
      #
      # @param workflow_id [String]
      # @return [Array<String>] aborted attempt ids
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

      # Port extension: return the canonical committed result for each
      # predecessor node in one storage call. The canonical result is either
      # the committed attempt with the highest `attempt_number` in the
      # requested revision, using `attempt_id.to_s` ASCII as a defensive
      # tie-break, or an explicit committed-result projection carried forward
      # when a preserved node remains `:committed` across a revision append.
      # Projections are not attempts and must not affect attempt counts.
      #
      # @param workflow_id [String]
      # @param revision [Integer]
      # @param predecessors [Array<Symbol>]
      # @return [Hash{Symbol => DAG::Success}]
      def list_committed_results_for_predecessors(workflow_id:, revision:, predecessors:)
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
