# frozen_string_literal: true

module DAG
  # Public, immutable runtime data visible to a step for one node attempt.
  # It is derived from StepInput metadata so consumers can inspect the scoped
  # execution boundary without reaching into storage internals.
  # @api public
  RuntimeSnapshot = Data.define(
    :workflow_id,
    :revision,
    :node_id,
    :attempt_id,
    :attempt_number,
    :predecessors,
    :effects,
    :metadata
  ) do
    class << self
      remove_method :[]

      # @param workflow_id [String]
      # @param revision [Integer]
      # @param node_id [Symbol]
      # @param attempt_id [String]
      # @param attempt_number [Integer]
      # @param predecessors [Hash] canonical predecessor Success snapshots
      # @param effects [Hash] node-scoped effect snapshots
      # @param metadata [Hash] JSON-safe extension data
      # @return [RuntimeSnapshot]
      def [](
        workflow_id:,
        revision:,
        node_id:,
        attempt_id:,
        attempt_number:,
        predecessors: {},
        effects: {},
        metadata: {}
      )
        new(
          workflow_id: workflow_id,
          revision: revision,
          node_id: node_id,
          attempt_id: attempt_id,
          attempt_number: attempt_number,
          predecessors: predecessors,
          effects: effects,
          metadata: metadata
        )
      end
    end

    def initialize(
      workflow_id:,
      revision:,
      node_id:,
      attempt_id:,
      attempt_number:,
      predecessors: {},
      effects: {},
      metadata: {}
    )
      DAG::Validation.string!(workflow_id, "workflow_id")
      DAG::Validation.revision!(revision)
      DAG::Validation.node_id!(node_id)
      DAG::Validation.string!(attempt_id, "attempt_id")
      DAG::Validation.positive_integer!(attempt_number, "attempt_number")
      DAG::Validation.hash!(predecessors, "predecessors")
      DAG::Validation.hash!(effects, "effects")
      DAG::Validation.hash!(metadata, "metadata")
      DAG.json_safe!(predecessors, "$root.predecessors")
      DAG.json_safe!(effects, "$root.effects")
      DAG.json_safe!(metadata, "$root.metadata")

      super(
        workflow_id: DAG.frozen_copy(workflow_id),
        revision: revision,
        node_id: node_id.to_sym,
        attempt_id: DAG.frozen_copy(attempt_id),
        attempt_number: attempt_number,
        predecessors: DAG.frozen_copy(predecessors),
        effects: DAG.frozen_copy(effects),
        metadata: DAG.frozen_copy(metadata)
      )
    end

    # @return [DAG::PlanVersion]
    def plan_version = DAG::PlanVersion[workflow_id: workflow_id, revision: revision]
  end
end
