# frozen_string_literal: true

module DAG
  # Step result indicating the step is waiting on an external condition.
  # `reason` is a Symbol, `resume_token` is JSON-safe, `not_before_ms` is
  # an optional wall-clock millisecond hint, and `proposed_effects` describes
  # blocking external effects that should make the node eligible later.
  # @api public
  Waiting = Data.define(:reason, :resume_token, :not_before_ms, :proposed_effects, :metadata) do
    class << self
      remove_method :[]

      # @param reason [Symbol]
      # @param resume_token [Object, nil] JSON-safe
      # @param not_before_ms [Integer, nil] wall-clock ms hint
      # @param proposed_effects [Array<DAG::Effects::Intent>]
      # @param metadata [Hash] JSON-safe
      # @return [Waiting]
      def [](reason:, resume_token: nil, not_before_ms: nil, proposed_effects: [], metadata: {})
        new(
          reason: reason,
          resume_token: resume_token,
          not_before_ms: not_before_ms,
          proposed_effects: proposed_effects,
          metadata: metadata
        )
      end
    end

    # Build a Waiting whose `not_before_ms` is derived from a `Time`-like
    # value.
    # @param reason [Symbol]
    # @param time [#to_f] seconds since epoch
    # @param resume_token [Object, nil]
    # @param proposed_effects [Array<DAG::Effects::Intent>]
    # @param metadata [Hash]
    # @return [Waiting]
    def self.at(reason:, time:, resume_token: nil, proposed_effects: [], metadata: {})
      self[
        reason: reason,
        resume_token: resume_token,
        not_before_ms: (time.to_f * 1000).to_i,
        proposed_effects: proposed_effects,
        metadata: metadata
      ]
    end

    def initialize(reason:, resume_token: nil, not_before_ms: nil, proposed_effects: [], metadata: {})
      DAG::Validation.symbol!(reason, "reason")
      DAG::Validation.optional_integer!(
        not_before_ms,
        "not_before_ms",
        message: "not_before_ms must be Integer milliseconds or nil"
      )

      DAG.json_safe!(resume_token, "$root.resume_token")
      DAG.json_safe!(metadata, "$root.metadata")
      DAG::Effects.validate_intents!(proposed_effects)

      super(
        reason: reason,
        resume_token: DAG.deep_freeze(DAG.deep_dup(resume_token)),
        not_before_ms: not_before_ms,
        proposed_effects: DAG.deep_freeze(proposed_effects.dup),
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end
end
