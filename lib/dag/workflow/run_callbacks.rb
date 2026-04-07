# frozen_string_literal: true

module DAG
  module Workflow
    RunCallbacks = Data.define(:on_step_start, :on_step_finish) do
      def initialize(on_step_start: nil, on_step_finish: nil) = super
      def start(name, step) = on_step_start&.call(name, step)
      def finish(name, result) = on_step_finish&.call(name, result)
    end
  end
end
