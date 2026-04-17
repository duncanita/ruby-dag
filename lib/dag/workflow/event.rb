# frozen_string_literal: true

module DAG
  module Workflow
    Event = Data.define(:name, :workflow_id, :node_path, :payload, :metadata, :emitted_at) do
      def initialize(name:, workflow_id:, node_path:, payload:, emitted_at:, metadata: {})
        super(
          name: name.to_sym,
          workflow_id: workflow_id,
          node_path: Array(node_path).map(&:to_sym).freeze,
          payload: payload,
          metadata: metadata || {},
          emitted_at: emitted_at
        )
      end
    end
  end
end
