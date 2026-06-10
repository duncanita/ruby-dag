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
        resume_token: DAG.frozen_copy(resume_token),
        not_before_ms: not_before_ms,
        proposed_effects: DAG.frozen_copy(proposed_effects),
        metadata: DAG.frozen_copy(metadata)
      )
    end

    # Full-fidelity JSON-safe projection; round-trips via {Result.from_h}.
    # @return [Hash]
    def to_h
      {
        status: :waiting,
        reason: reason,
        resume_token: resume_token,
        not_before_ms: not_before_ms,
        proposed_effects: proposed_effects.map(&:to_h),
        metadata: metadata
      }
    end

    # Rebuild a Waiting from a {#to_h} projection (Symbol or String keys).
    # @param hash [Hash]
    # @return [Waiting]
    def self.from_h(hash)
      DAG::Validation.hash!(hash, "waiting hash")
      new(
        reason: DAG::Snapshot.fetch!(hash, :reason).to_sym,
        resume_token: DAG::Snapshot.fetch(hash, :resume_token),
        not_before_ms: DAG::Snapshot.fetch(hash, :not_before_ms),
        proposed_effects: DAG::Snapshot.fetch(hash, :proposed_effects, []).map { |i| DAG::Effects::Intent.from_h(i) },
        metadata: DAG::Snapshot.fetch(hash, :metadata, {})
      )
    end
  end
end
