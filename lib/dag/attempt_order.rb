# frozen_string_literal: true

module DAG
  # Canonical committed-attempt ordering: the attempt with the highest
  # `attempt_number` wins, with `attempt_id.to_s` ASCII as a defensive
  # tie-break. This is a determinism-critical rule — the Runner's effective
  # context depends on which committed attempt is canonical — so it has
  # exactly one executable definition, shared by the storage port default,
  # the Memory adapter, and diagnostics.
  # @api private
  module AttemptOrder
    module_function

    # True when `candidate` outranks `current` (or `current` is nil).
    # @param candidate [Hash] attempt record with :attempt_number, :attempt_id
    # @param current [Hash, nil]
    # @return [Boolean]
    def better?(candidate, current)
      return true if current.nil?

      candidate_number = candidate.fetch(:attempt_number)
      current_number = current.fetch(:attempt_number)
      return true if candidate_number > current_number
      return false unless candidate_number == current_number

      candidate.fetch(:attempt_id).to_s > current.fetch(:attempt_id).to_s
    end

    # Sort key under the canonical ordering (ascending: last element is the
    # canonical attempt).
    # @param attempt [Hash] attempt record with :attempt_number, :attempt_id
    # @return [Array(Integer, String)]
    def key(attempt)
      [attempt.fetch(:attempt_number), attempt.fetch(:attempt_id).to_s]
    end
  end
end
