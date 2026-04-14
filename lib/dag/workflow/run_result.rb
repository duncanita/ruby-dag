# frozen_string_literal: true

module DAG
  module Workflow
    class RunResult < Data.define(:status, :workflow_id, :outputs, :trace, :error, :waiting_nodes)
      VALID_STATUSES = %i[completed failed waiting paused].freeze

      def initialize(status:, workflow_id:, outputs:, trace:, error:, waiting_nodes:)
        unless VALID_STATUSES.include?(status)
          raise ArgumentError, "invalid run result status: #{status.inspect}"
        end

        if error && status != :failed
          raise ArgumentError, "run result error is only valid for failed workflows"
        end

        if waiting_nodes.any? && status != :waiting
          raise ArgumentError, "waiting_nodes is only valid for waiting workflows"
        end

        super
      end

      def completed? = status == :completed
      def failed? = status == :failed
      def waiting? = status == :waiting
      def paused? = status == :paused

      # Compatibility predicates while callers migrate away from the old
      # workflow-level Result wrapper.
      def success? = completed?
      def failure? = failed?
    end
  end
end
