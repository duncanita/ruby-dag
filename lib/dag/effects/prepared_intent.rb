# frozen_string_literal: true

module DAG
  module Effects
    # Kernel-enriched form of an Intent ready to be persisted atomically with
    # an attempt commit.
    # @api public
    PreparedIntent = Data.define(
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
      :created_at_ms,
      :metadata
    ) do
      class << self
        remove_method :[]

        # `ref` is derived from `type:key`; the factory does not accept it.
        # @return [PreparedIntent]
        def [](
          workflow_id:,
          revision:,
          node_id:,
          attempt_id:,
          type:,
          key:,
          payload:,
          payload_fingerprint:,
          blocking:,
          created_at_ms:,
          metadata: {}
        )
          new(
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            attempt_id: attempt_id,
            type: type,
            key: key,
            payload: payload,
            payload_fingerprint: payload_fingerprint,
            blocking: blocking,
            created_at_ms: created_at_ms,
            metadata: metadata
          )
        end

        # Build a PreparedIntent from the public step-level intent plus the
        # kernel-owned execution coordinates.
        # @param intent [DAG::Effects::Intent]
        # @return [PreparedIntent]
        def from_intent(
          intent:,
          workflow_id:,
          revision:,
          node_id:,
          attempt_id:,
          payload_fingerprint:,
          blocking:,
          created_at_ms:,
          metadata: nil
        )
          raise ArgumentError, "intent must be DAG::Effects::Intent" unless intent.is_a?(DAG::Effects::Intent)

          new(
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            attempt_id: attempt_id,
            type: intent.type,
            key: intent.key,
            payload: intent.payload,
            payload_fingerprint: payload_fingerprint,
            blocking: blocking,
            created_at_ms: created_at_ms,
            metadata: metadata.nil? ? intent.metadata : metadata
          )
        end
      end

      def initialize(
        workflow_id:,
        revision:,
        node_id:,
        attempt_id:,
        type:,
        key:,
        payload:,
        payload_fingerprint:,
        blocking:,
        created_at_ms:,
        metadata: {},
        ref: nil
      )
        # `ref:` is accepted only so `Data#with` round-trips correctly. It is
        # always recomputed from `type:key` below; user input passes through
        # `[]`, which does not expose the kwarg.
        DAG::Effects.validate_ref_part!(type, "type")
        DAG::Effects.validate_ref_part!(key, "key")
        DAG::Validation.string!(workflow_id, "workflow_id")
        DAG::Validation.revision!(revision)
        DAG::Validation.node_id!(node_id)
        DAG::Validation.string!(attempt_id, "attempt_id")
        DAG::Validation.string!(payload_fingerprint, "payload_fingerprint")
        DAG::Validation.boolean!(blocking, "blocking")
        DAG::Validation.integer!(created_at_ms, "created_at_ms")
        DAG.json_safe!(payload, "$root.payload")
        DAG.json_safe!(metadata, "$root.metadata")

        super(
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
          created_at_ms: created_at_ms,
          metadata: DAG.frozen_copy(metadata)
        )
      end
    end
  end
end
