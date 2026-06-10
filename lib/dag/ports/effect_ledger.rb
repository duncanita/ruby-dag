# frozen_string_literal: true

module DAG
  module Ports
    # Durable abstract effect ledger port. Split out of `Ports::Storage`
    # so the two disjoint consumers stay honest: the Runner never touches
    # the ledger beyond `commit_attempt(effects:)` and the listing reads,
    # and `DAG::Effects::Dispatcher` needs only this module's surface plus
    # `append_event`. Adapters that persist effects include this module
    # (directly or via `Ports::Storage`, which includes it).
    #
    # Adapters implement the primitives (`claim_ready_effects`,
    # `mark_effect_*`, `renew_effect_lease`,
    # `release_nodes_satisfied_by_effect`). The composed
    # `complete_effect_*` methods have default implementations built from
    # those primitives; durable adapters should override them with a single
    # atomic transaction, because the default composition has a crash
    # window between the terminal mark and the node release.
    #
    # @api public
    module EffectLedger
      # Whether the adapter may be driven by `Dispatcher` worker threads
      # (`parallelism > 1`). Defaults to `false`; single-process adapters
      # such as `Memory::Storage` must keep it `false`.
      # @return [Boolean]
      def thread_safe_for_dispatch?
        false
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
      # @param only_workflow_id [String, nil] when non-nil, restrict the claim to
      #   effects that have at least one attempt-effect link belonging to the given
      #   workflow. This matches the kernel's idempotency model: a single effect
      #   record can be shared across workflows via attempt links, so the filter
      #   resolves "effects this workflow is waiting on", not "effects this
      #   workflow created first". Default `nil` claims globally across all
      #   workflows (V1.3 behaviour). A workflow with no linked effects yields an
      #   empty array (no raise). V1.4.
      # @return [Array<DAG::Effects::Record>] claimed records
      def claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:, only_workflow_id: nil)
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

      # Cooperatively extend the lease of an effect currently held by
      # `owner_id`. This separates admission control (worker-death detection
      # via expired lease) from handler execution time, so the dispatcher's
      # default `lease_ms` can stay tight without forcing legitimately
      # long-running handlers to lose their claim mid-run.
      #
      # The CAS guard is identical to `mark_effect_*`: status `:dispatching`,
      # `lease_owner == owner_id`, and `lease_until_ms >= now_ms`. Adapters
      # update `lease_until_ms` and `updated_at_ms` atomically. Renewal is
      # monotonic: `until_ms` must be strictly greater than `now_ms` and not
      # less than the current `lease_until_ms`. `until_ms == lease_until_ms`
      # is a no-op success that returns the unchanged record.
      #
      # @param effect_id [String]
      # @param owner_id [String] current lease owner
      # @param until_ms [Integer] new lease deadline in wall-clock milliseconds
      # @param now_ms [Integer]
      # @return [DAG::Effects::Record] updated record with the extended lease
      # @raise [DAG::Effects::UnknownEffectError] when `effect_id` is unknown
      # @raise [DAG::Effects::StaleLeaseError] when the lease is missing, expired, or owned by another dispatcher
      # @raise [ArgumentError] when `until_ms` is not greater than `now_ms`,
      #   or would shrink the existing `lease_until_ms`
      def renew_effect_lease(effect_id:, owner_id:, until_ms:, now_ms:)
        raise PortNotImplementedError
      end

      # Canonical completion path: mark a claimed effect as succeeded and
      # release any waiting nodes that become satisfied by that terminal
      # effect state.
      #
      # The default implementation composes `mark_effect_succeeded` and
      # `release_nodes_satisfied_by_effect` and is therefore NOT crash-atomic:
      # a crash between the two calls durably leaves a terminal effect whose
      # waiting nodes were never released. Durable adapters must override
      # this with one atomic transaction.
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
        updated = mark_effect_succeeded(
          effect_id: effect_id,
          owner_id: owner_id,
          result: result,
          external_ref: external_ref,
          now_ms: now_ms
        )
        released = release_nodes_satisfied_by_effect(effect_id: effect_id, now_ms: now_ms)
        {record: updated, released: released}
      end

      # Canonical completion path: mark a claimed effect as failed and
      # release waiting nodes when the resulting failure is terminal.
      #
      # Same crash-window caveat as {#complete_effect_succeeded}: the default
      # composition is not atomic; durable adapters must override it.
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
        updated = mark_effect_failed(
          effect_id: effect_id,
          owner_id: owner_id,
          error: error,
          retriable: retriable,
          not_before_ms: not_before_ms,
          now_ms: now_ms
        )
        released = updated.terminal? ? release_nodes_satisfied_by_effect(effect_id: effect_id, now_ms: now_ms) : []
        {record: updated, released: released}
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
    end
  end
end
