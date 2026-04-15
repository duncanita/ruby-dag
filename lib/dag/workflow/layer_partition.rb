# frozen_string_literal: true

module DAG
  module Workflow
    ImmediateResult = Data.define(:name, :result, :input_keys, :status)
    LayerPartition = Data.define(:runnable, :immediate_results, :waiting_nodes)
  end
end
