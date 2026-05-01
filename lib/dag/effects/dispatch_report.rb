# frozen_string_literal: true

module DAG
  module Effects
    # Immutable summary returned by `DAG::Effects::Dispatcher#tick`.
    # @api public
    DispatchReport = Data.define(:claimed, :succeeded, :failed, :released, :errors) do
      class << self
        remove_method :[]

        # @param claimed [Array<DAG::Effects::Record>]
        # @param succeeded [Array<DAG::Effects::Record>]
        # @param failed [Array<DAG::Effects::Record>]
        # @param released [Array<Hash>]
        # @param errors [Array<Hash>]
        # @return [DispatchReport]
        def [](claimed: [], succeeded: [], failed: [], released: [], errors: [])
          new(claimed: claimed, succeeded: succeeded, failed: failed, released: released, errors: errors)
        end
      end

      def initialize(claimed: [], succeeded: [], failed: [], released: [], errors: [])
        DAG::Validation.array!(claimed, "claimed")
        DAG::Validation.array!(succeeded, "succeeded")
        DAG::Validation.array!(failed, "failed")
        DAG::Validation.array!(released, "released")
        DAG::Validation.array!(errors, "errors")
        DAG.json_safe!(released, "$root.released")
        DAG.json_safe!(errors, "$root.errors")

        super(
          claimed: DAG.deep_freeze(claimed.dup),
          succeeded: DAG.deep_freeze(succeeded.dup),
          failed: DAG.deep_freeze(failed.dup),
          released: DAG.deep_freeze(DAG.deep_dup(released)),
          errors: DAG.deep_freeze(DAG.deep_dup(errors))
        )
      end
    end
  end
end
