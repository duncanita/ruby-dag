# frozen_string_literal: true

module DAG
  # Result returned by `Runner#call`, `Runner#resume`, and
  # `Runner#retry_workflow`. `state` is the terminal workflow state;
  # `last_event_seq` is the last durably-appended event's `seq` (or `nil`).
  # @api public
  RunResult = Data.define(:state, :last_event_seq, :outcome, :metadata) do
    class << self
      remove_method :[]

      # @param state [Symbol]
      # @param last_event_seq [Integer, nil]
      # @param outcome [Hash, nil] JSON-safe
      # @param metadata [Hash] JSON-safe
      # @return [RunResult]
      def [](state:, last_event_seq: nil, outcome: nil, metadata: {})
        new(
          state: state,
          last_event_seq: last_event_seq,
          outcome: outcome,
          metadata: metadata
        )
      end
    end

    def initialize(state:, last_event_seq: nil, outcome: nil, metadata: {})
      DAG.json_safe!(outcome, "$root.outcome")
      DAG.json_safe!(metadata, "$root.metadata")

      super(
        state: state,
        last_event_seq: last_event_seq,
        outcome: DAG.deep_freeze(DAG.deep_dup(outcome)),
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end
end
