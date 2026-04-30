# frozen_string_literal: true

module DAG
  module Adapters
    module Memory
      # Raised by `CrashableStorage` to simulate a process crash mid-call.
      # @api public
      class SimulatedCrash < DAG::Error
      end

      # Test adapter that injects deterministic crashes around storage calls.
      # It shares Memory::Storage semantics and can export a healthy snapshot
      # to simulate process restart after the crash has been observed.
      # @api public
      class CrashableStorage < Storage
        # @param crash_on [Hash] crash trigger spec (`:method`, `:before`/`:after`, plus optional context filters)
        # @param initial_state [Hash, nil]
        def initialize(crash_on:, initial_state: nil)
          super(initial_state: initial_state)
          @crash_on = normalize_crash_on(crash_on)
          @crashed = false
        end

        # (see Ports::Storage#begin_attempt)
        def begin_attempt(workflow_id:, revision:, node_id:, expected_node_state:, attempt_number:)
          context = {
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            attempt_number: attempt_number
          }
          crash_if!(:before, :begin_attempt, context)
          attempt_id = super
          crash_if!(:after, :begin_attempt, context.merge(attempt_id: attempt_id))
          attempt_id
        end

        # (see Ports::Storage#commit_attempt)
        def commit_attempt(attempt_id:, result:, node_state:, event:, effects: [])
          context = attempt_context(attempt_id).merge(node_state: node_state)
          crash_if_any!(%i[before_commit before], :commit_attempt, context)
          stamped = super
          crash_if_any!(%i[after_commit after], :commit_attempt, context)
          stamped
        end

        # (see Ports::Storage#append_event)
        def append_event(workflow_id:, event:)
          context = {workflow_id: workflow_id, event_type: event.type}
          crash_if!(:before, :append_event, context)
          stamped = super
          crash_if!(:after, :append_event, context)
          stamped
        end

        # (see Ports::Storage#transition_workflow_state)
        def transition_workflow_state(id:, from:, to:, event: nil)
          context = {workflow_id: id, from: from, to: to}
          crash_if!(:before, :transition_workflow_state, context)
          row = super
          crash_if!(:after, :transition_workflow_state, context)
          row
        end

        # (see Ports::Storage#prepare_workflow_retry)
        def prepare_workflow_retry(id:, from: :failed, to: :pending, event: nil)
          context = {workflow_id: id, from: from, to: to}
          crash_if!(:before, :prepare_workflow_retry, context)
          row = super
          crash_if!(:after, :prepare_workflow_retry, context)
          row
        end

        # Export the underlying state into a fresh `Memory::Storage`
        # without crash injection. Mirrors a process restart after the
        # simulated crash has been observed.
        # @return [Storage]
        def snapshot_to_healthy
          Storage.new(initial_state: DAG.deep_dup(@state))
        end

        private

        def normalize_crash_on(crash_on)
          crash_on.transform_keys(&:to_sym)
        end

        def attempt_context(attempt_id)
          attempt = @state[:attempts].fetch(attempt_id) do
            raise ArgumentError, "Unknown attempt: #{attempt_id}"
          end

          {
            attempt_id: attempt_id,
            workflow_id: attempt[:workflow_id],
            revision: attempt[:revision],
            node_id: attempt[:node_id],
            attempt_number: attempt[:attempt_number]
          }
        end

        def crash_if_any!(phases, method, context)
          phases.each { |phase| crash_if!(phase, method, context) }
        end

        def crash_if!(phase, method, context)
          return if @crashed
          return unless @crash_on[:method]&.to_sym == method
          return unless @crash_on[phase]
          return unless trigger_context_matches?(context)

          @crashed = true
          raise SimulatedCrash, "simulated crash on #{method} #{phase}"
        end

        def trigger_context_matches?(context)
          %i[workflow_id revision node_id attempt_id attempt_number node_state event_type from to].all? do |key|
            !@crash_on.key?(key) || @crash_on[key] == context[key]
          end
        end
      end
    end
  end
end
