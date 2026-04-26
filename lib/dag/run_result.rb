# frozen_string_literal: true

module DAG
  RunResult = Data.define(:state, :last_event_seq, :outcome, :metadata) do
    class << self
      remove_method :[]

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
