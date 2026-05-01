# frozen_string_literal: true

module DAG
  module Effects
    RECORD_SNAPSHOT_FIELDS = %i[
      id
      ref
      type
      key
      payload
      payload_fingerprint
      blocking
      status
      result
      error
      external_ref
      not_before_ms
      metadata
    ].freeze
    private_constant :RECORD_SNAPSHOT_FIELDS

    # Durable effect snapshot returned by effect-aware storage adapters.
    # @api public
    Record = Data.define(
      :id,
      :ref,
      :workflow_id,
      :revision,
      :node_id,
      :attempt_id,
      :type,
      :key,
      :payload,
      :payload_fingerprint,
      :blocking,
      :status,
      :result,
      :error,
      :external_ref,
      :not_before_ms,
      :lease_owner,
      :lease_until_ms,
      :created_at_ms,
      :updated_at_ms,
      :metadata
    ) do
      class << self
        remove_method :[]

        # `ref` is derived from `type:key`; the factory does not accept it.
        # @return [Record]
        def [](
          id:,
          workflow_id:,
          revision:,
          node_id:,
          attempt_id:,
          type:,
          key:,
          payload:,
          payload_fingerprint:,
          blocking:,
          status:,
          created_at_ms:,
          updated_at_ms:,
          result: nil,
          error: nil,
          external_ref: nil,
          not_before_ms: nil,
          lease_owner: nil,
          lease_until_ms: nil,
          metadata: {}
        )
          new(
            id: id,
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            attempt_id: attempt_id,
            type: type,
            key: key,
            payload: payload,
            payload_fingerprint: payload_fingerprint,
            blocking: blocking,
            status: status,
            result: result,
            error: error,
            external_ref: external_ref,
            not_before_ms: not_before_ms,
            lease_owner: lease_owner,
            lease_until_ms: lease_until_ms,
            created_at_ms: created_at_ms,
            updated_at_ms: updated_at_ms,
            metadata: metadata
          )
        end

        # Build a durable effect snapshot from a kernel-prepared intent.
        # @param prepared_intent [DAG::Effects::PreparedIntent]
        # @return [Record]
        def from_prepared(
          id:,
          prepared_intent:,
          status:,
          updated_at_ms:,
          created_at_ms: nil,
          result: nil,
          error: nil,
          external_ref: nil,
          not_before_ms: nil,
          lease_owner: nil,
          lease_until_ms: nil,
          metadata: nil
        )
          DAG::Validation.instance!(
            prepared_intent,
            DAG::Effects::PreparedIntent,
            "prepared_intent"
          )

          new(
            id: id,
            workflow_id: prepared_intent.workflow_id,
            revision: prepared_intent.revision,
            node_id: prepared_intent.node_id,
            attempt_id: prepared_intent.attempt_id,
            type: prepared_intent.type,
            key: prepared_intent.key,
            payload: prepared_intent.payload,
            payload_fingerprint: prepared_intent.payload_fingerprint,
            blocking: prepared_intent.blocking,
            status: status,
            created_at_ms: created_at_ms || prepared_intent.created_at_ms,
            updated_at_ms: updated_at_ms,
            result: result,
            error: error,
            external_ref: external_ref,
            not_before_ms: not_before_ms,
            lease_owner: lease_owner,
            lease_until_ms: lease_until_ms,
            metadata: metadata.nil? ? prepared_intent.metadata : metadata
          )
        end
      end

      def initialize(
        id:,
        workflow_id:,
        revision:,
        node_id:,
        attempt_id:,
        type:,
        key:,
        payload:,
        payload_fingerprint:,
        blocking:,
        status:,
        created_at_ms:,
        updated_at_ms:,
        result: nil,
        error: nil,
        external_ref: nil,
        not_before_ms: nil,
        lease_owner: nil,
        lease_until_ms: nil,
        metadata: {},
        ref: nil
      )
        # `ref:` is accepted only so `Data#with` round-trips correctly. It is
        # always recomputed from `type:key` below; user input passes through
        # `[]`, which does not expose the kwarg.
        DAG::Validation.string!(id, "id")
        DAG::Effects.validate_ref_part!(type, "type")
        DAG::Effects.validate_ref_part!(key, "key")
        DAG::Validation.string!(workflow_id, "workflow_id")
        DAG::Validation.revision!(revision)
        DAG::Validation.node_id!(node_id)
        DAG::Validation.string!(attempt_id, "attempt_id")
        DAG::Validation.string!(payload_fingerprint, "payload_fingerprint")
        DAG::Validation.boolean!(blocking, "blocking")
        validate_status!(status)
        DAG::Validation.optional_integer!(not_before_ms, "not_before_ms")
        DAG::Validation.optional_integer!(lease_until_ms, "lease_until_ms")
        DAG::Validation.integer!(created_at_ms, "created_at_ms")
        DAG::Validation.integer!(updated_at_ms, "updated_at_ms")
        DAG.json_safe!(payload, "$root.payload")
        DAG.json_safe!(result, "$root.result")
        DAG.json_safe!(error, "$root.error")
        DAG.json_safe!(external_ref, "$root.external_ref")
        DAG.json_safe!(lease_owner, "$root.lease_owner")
        DAG.json_safe!(metadata, "$root.metadata")

        super(
          id: DAG.frozen_copy(id),
          ref: DAG::Effects.ref_for(type, key),
          workflow_id: DAG.frozen_copy(workflow_id),
          revision: revision,
          node_id: DAG.frozen_copy(node_id),
          attempt_id: DAG.frozen_copy(attempt_id),
          type: DAG.frozen_copy(type),
          key: DAG.frozen_copy(key),
          payload: DAG.frozen_copy(payload),
          payload_fingerprint: DAG.frozen_copy(payload_fingerprint),
          blocking: blocking,
          status: status,
          result: DAG.frozen_copy(result),
          error: DAG.frozen_copy(error),
          external_ref: DAG.frozen_copy(external_ref),
          not_before_ms: not_before_ms,
          lease_owner: DAG.frozen_copy(lease_owner),
          lease_until_ms: lease_until_ms,
          created_at_ms: created_at_ms,
          updated_at_ms: updated_at_ms,
          metadata: DAG.frozen_copy(metadata)
        )
      end

      # @return [Boolean]
      def terminal? = DAG::Effects::TERMINAL_STATUSES.include?(status)

      # Stable Hash shape injected into `StepInput#metadata[:effects]`.
      # @return [Hash]
      def to_snapshot
        DAG.deep_freeze(RECORD_SNAPSHOT_FIELDS.map { |field| [field, public_send(field)] }.to_h)
      end

      private

      def validate_status!(value)
        DAG::Validation.member!(
          value,
          DAG::Effects::STATUSES,
          "status",
          message: "invalid effect status: #{value.inspect}"
        )
      end
    end
  end
end
