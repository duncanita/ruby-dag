# frozen_string_literal: true

module DAG
  module Effects
    # Pure description of an external side effect. `(type, key)` is the
    # semantic identity; payload is guarded later by a fingerprint.
    # @api public
    Intent = Data.define(:type, :key, :payload, :metadata) do
      class << self
        remove_method :[]

        # @param type [String]
        # @param key [String]
        # @param payload [Hash, Array, String, Integer, Float, Boolean, nil] JSON-safe
        # @param metadata [Hash] JSON-safe
        # @return [Intent]
        def [](type:, key:, payload: {}, metadata: {})
          new(type: type, key: key, payload: payload, metadata: metadata)
        end
      end

      def initialize(type:, key:, payload: {}, metadata: {})
        DAG::Effects.validate_ref_part!(type, "type")
        DAG::Effects.validate_ref_part!(key, "key")
        DAG.json_safe!(payload, "$root.payload")
        DAG.json_safe!(metadata, "$root.metadata")
        @ref = DAG::Effects.ref_for(type, key)

        super(
          type: DAG.frozen_copy(type),
          key: DAG.frozen_copy(key),
          payload: DAG.frozen_copy(payload),
          metadata: DAG.frozen_copy(metadata)
        )
      end

      # @return [String] deterministic effect reference
      def ref = @ref
    end
  end
end
