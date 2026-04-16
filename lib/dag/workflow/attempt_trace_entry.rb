# frozen_string_literal: true

module DAG
  module Workflow
    AttemptTraceEntry = Data.define(:node_path, :started_at, :finished_at, :duration_ms, :status, :attempt)
  end
end
