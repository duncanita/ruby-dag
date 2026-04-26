# frozen_string_literal: true

module DAG
  Waiting = Data.define(:reason, :resume_token, :not_before_ms, :metadata) do
    class << self
      remove_method :[]

      def [](reason:, resume_token: nil, not_before_ms: nil, metadata: {})
        new(
          reason: reason,
          resume_token: resume_token,
          not_before_ms: not_before_ms,
          metadata: metadata
        )
      end
    end

    def self.at(reason:, time:, resume_token: nil, metadata: {})
      self[
        reason: reason,
        resume_token: resume_token,
        not_before_ms: (time.to_f * 1000).to_i,
        metadata: metadata
      ]
    end

    def initialize(reason:, resume_token: nil, not_before_ms: nil, metadata: {})
      raise ArgumentError, "reason must be Symbol" unless reason.is_a?(Symbol)
      unless not_before_ms.nil? || not_before_ms.is_a?(Integer)
        raise ArgumentError, "not_before_ms must be Integer milliseconds or nil"
      end

      DAG.json_safe!(resume_token, "$root.resume_token")
      DAG.json_safe!(metadata, "$root.metadata")

      super(
        reason: reason,
        resume_token: DAG.deep_freeze(DAG.deep_dup(resume_token)),
        not_before_ms: not_before_ms,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end
end
