# frozen_string_literal: true

module DAG
  # Public, immutable node diagnostic derived from storage-owned node state,
  # attempts, and abstract effect records. It intentionally excludes any UI,
  # model, prompt, channel, or runtime-specific object.
  # @api public
  NodeDiagnostic = Data.define(
    :workflow_id,
    :revision,
    :node_id,
    :state,
    :terminal,
    :attempt_count,
    :last_attempt_id,
    :last_error_code,
    :last_error_attempt_id,
    :waiting_reason,
    :effect_refs,
    :effect_statuses,
    :effects_terminal
  ) do
    class << self
      remove_method :[]

      # Build a diagnostic from storage records for one workflow node.
      # @param workflow_id [String]
      # @param revision [Integer]
      # @param node_id [Symbol]
      # @param state [Symbol]
      # @param attempts [Array<Hash>]
      # @param effects [Array<DAG::Effects::Record>]
      # @return [DAG::NodeDiagnostic]
      def from_records(workflow_id:, revision:, node_id:, state:, attempts:, effects: [])
        sorted_attempts = attempts.sort_by { |attempt| [attempt.fetch(:attempt_number), attempt.fetch(:attempt_id).to_s] }
        sorted_effects = effects.sort_by(&:ref)
        failure_attempt = sorted_attempts.reverse_each.find { |attempt| attempt.fetch(:result).is_a?(DAG::Failure) }
        waiting_attempt = sorted_attempts.reverse_each.find { |attempt| attempt.fetch(:result).is_a?(DAG::Waiting) }
        effect_statuses = sorted_effects.to_h { |record| [record.ref, record.status] }

        new(
          workflow_id: workflow_id,
          revision: revision,
          node_id: node_id,
          state: state,
          terminal: DAG::NodeDiagnostic::TERMINAL_NODE_STATES.include?(state),
          attempt_count: sorted_attempts.size,
          last_attempt_id: sorted_attempts.last&.fetch(:attempt_id),
          last_error_code: error_code(failure_attempt&.fetch(:result)&.error),
          last_error_attempt_id: failure_attempt&.fetch(:attempt_id),
          waiting_reason: (waiting_attempt&.fetch(:result)&.reason if state == :waiting),
          effect_refs: sorted_effects.map(&:ref),
          effect_statuses: effect_statuses,
          effects_terminal: effects_terminal(sorted_effects)
        )
      end

      # @return [DAG::NodeDiagnostic]
      def [](
        workflow_id:,
        revision:,
        node_id:,
        state:,
        terminal:,
        attempt_count:,
        last_attempt_id: nil,
        last_error_code: nil,
        last_error_attempt_id: nil,
        waiting_reason: nil,
        effect_refs: [],
        effect_statuses: {},
        effects_terminal: nil
      )
        new(
          workflow_id: workflow_id,
          revision: revision,
          node_id: node_id,
          state: state,
          terminal: terminal,
          attempt_count: attempt_count,
          last_attempt_id: last_attempt_id,
          last_error_code: last_error_code,
          last_error_attempt_id: last_error_attempt_id,
          waiting_reason: waiting_reason,
          effect_refs: effect_refs,
          effect_statuses: effect_statuses,
          effects_terminal: effects_terminal
        )
      end

      private

      def error_code(error)
        return nil if error.nil?
        code = error.fetch(:code) { error.fetch("code", nil) } if error.is_a?(Hash)
        code = error if error.is_a?(String) || error.is_a?(Symbol) || error.is_a?(Integer)

        return code if code.is_a?(String) || code.is_a?(Symbol) || code.is_a?(Integer)

        nil
      end

      def effects_terminal(effects)
        return nil if effects.empty?

        effects.all?(&:terminal?)
      end
    end

    def initialize(
      workflow_id:,
      revision:,
      node_id:,
      state:,
      terminal:,
      attempt_count:,
      last_attempt_id: nil,
      last_error_code: nil,
      last_error_attempt_id: nil,
      waiting_reason: nil,
      effect_refs: [],
      effect_statuses: {},
      effects_terminal: nil
    )
      DAG::Validation.string!(workflow_id, "workflow_id")
      DAG::Validation.revision!(revision)
      DAG::Validation.node_id!(node_id)
      DAG::Validation.symbol!(state, "state")
      DAG::Validation.boolean!(terminal, "terminal")
      DAG::Validation.nonnegative_integer!(attempt_count, "attempt_count")
      DAG::Validation.string!(last_attempt_id, "last_attempt_id") unless last_attempt_id.nil?
      DAG::Validation.string!(last_error_attempt_id, "last_error_attempt_id") unless last_error_attempt_id.nil?
      validate_error_code!(last_error_code)
      DAG::Validation.string_or_symbol!(waiting_reason, "waiting_reason") unless waiting_reason.nil?
      DAG::Validation.array!(effect_refs, "effect_refs")
      DAG::Validation.hash!(effect_statuses, "effect_statuses")
      DAG::Validation.boolean!(effects_terminal, "effects_terminal") unless effects_terminal.nil?
      DAG.json_safe!(effect_refs, "$root.effect_refs")
      DAG.json_safe!(effect_statuses, "$root.effect_statuses")

      super(
        workflow_id: DAG.frozen_copy(workflow_id),
        revision: revision,
        node_id: node_id.to_sym,
        state: state,
        terminal: terminal,
        attempt_count: attempt_count,
        last_attempt_id: DAG.frozen_copy(last_attempt_id),
        last_error_code: last_error_code,
        last_error_attempt_id: DAG.frozen_copy(last_error_attempt_id),
        waiting_reason: waiting_reason,
        effect_refs: DAG.frozen_copy(effect_refs),
        effect_statuses: DAG.frozen_copy(effect_statuses),
        effects_terminal: effects_terminal
      )
    end

    private

    # @api private
    # @return [void]
    def validate_error_code!(code)
      return if code.nil? || code.is_a?(String) || code.is_a?(Symbol) || code.is_a?(Integer)

      raise ArgumentError, "last_error_code must be String, Symbol, Integer, or nil"
    end

    public

    # @return [Hash] JSON-safe, deterministic public representation.
    def to_h
      DAG.frozen_copy(
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        state: state,
        terminal: terminal,
        attempt_count: attempt_count,
        last_attempt_id: last_attempt_id,
        last_error_code: last_error_code,
        last_error_attempt_id: last_error_attempt_id,
        waiting_reason: waiting_reason,
        effect_refs: effect_refs,
        effect_statuses: effect_statuses,
        effects_terminal: effects_terminal
      )
    end
  end

  # Node states that no longer need runner scheduling in the current revision.
  NodeDiagnostic::TERMINAL_NODE_STATES = %i[committed failed].freeze
end
