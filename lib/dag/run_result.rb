# frozen_string_literal: true

module DAG
  RunResult = Data.define(:state, :last_event_seq, :outcome, :metadata) do
    def initialize(state:, last_event_seq: nil, outcome: nil, metadata: {})
      super(
        state: state,
        last_event_seq: last_event_seq,
        outcome: DAG.deep_freeze(DAG.deep_dup(outcome)),
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end
end
