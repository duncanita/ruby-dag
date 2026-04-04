# frozen_string_literal: true

module DAG
  module Workflow
    RunCallbacks = Data.define(:on_node_start, :on_node_finish) do
      def initialize(on_node_start: nil, on_node_finish: nil) = super
      def start(name, node) = on_node_start&.call(name, node)
      def finish(name, result) = on_node_finish&.call(name, result)
    end
  end
end
