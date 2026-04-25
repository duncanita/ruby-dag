# frozen_string_literal: true

module DAG
  module Workflow
    ImmediateResult = Data.define(:name, :result, :input_keys, :status)
    BlockedResult = Data.define(:name, :predecessor, :predecessor_status, :input_keys)
    LayerPartition = Data.define(:runnable, :immediate_results, :waiting_nodes, :blocked_results)
  end
end
