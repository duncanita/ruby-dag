# frozen_string_literal: true

module DAG
  # Marker module included by Success and Failure. Use `result.is_a?(DAG::Result)`
  # to type-check a value monad. The actual contract (`success?`, `failure?`,
  # `value`, `error`, `and_then`, `map`, `map_error`, `unwrap!`, `value_or`, `to_h`)
  # lives on Success and Failure themselves.
  module Result
  end
end
