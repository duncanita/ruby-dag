# frozen_string_literal: true

module DAG
  # Marker module included by Success and Failure. Use `result.is_a?(DAG::Result)`
  # to type-check a value monad.
  #
  # The full contract lives on Success and Failure themselves:
  #   success? / failure?    -- branch predicates
  #   value / error          -- payload accessors (one is always nil)
  #   and_then { |v| ... }   -- chain on success; passes through on failure
  #   map { |v| ... }        -- transform value on success; passes through on failure
  #   map_error { |e| ... }  -- transform error on failure; passes through on success
  #   tap { |v| ... }        -- side-effect on success, returns self
  #   tap_error { |e| ... }  -- side-effect on failure, returns self
  #   recover { |e| ... }    -- failure → result (lets you turn failure back into success)
  #   unwrap!                -- value on success, raises on failure
  #   value_or(default)      -- value on success, default on failure
  #   to_h                   -- {status:, value:|error:}
  #
  # `and_then` and `recover` MUST return a Result. The block result is checked
  # and a clean error is raised if not — this catches the most common monad
  # programming mistake (forgetting to wrap the return value).
  module Result
    # Run `block` and return Success(its return value), or Failure(the exception
    # message) if it raises a StandardError. Use this to integrate with code
    # that throws instead of returning a Result.
    #
    #   DAG::Result.try { JSON.parse(input) }   # => Success(...) or Failure("...")
    #
    # `error_class:` lets you narrow what is caught (defaults to StandardError).
    def self.try(error_class: StandardError)
      Success.new(value: yield)
    rescue error_class => e
      Failure.new(error: "#{e.class}: #{e.message}")
    end

    # Internal helper used by `and_then` / `recover` to enforce the contract.
    def self.assert_result!(value, source)
      return value if value.is_a?(Result)
      raise TypeError, "#{source} block must return a DAG::Result, got #{value.class}"
    end
  end
end
