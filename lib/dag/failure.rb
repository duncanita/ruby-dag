# frozen_string_literal: true

module DAG
  Failure = Data.define(:error) do
    include Result

    def success? = false
    def failure? = true
    def value = nil

    def and_then = self
    def map = self
    def map_error = Failure.new(error: yield(error))
    def unwrap! = raise("Unwrap called on Failure: #{error}")
    def value_or(default) = default
    def to_h = {status: :failure, error: error}
    def inspect = "Failure(#{error.inspect})"
    alias_method :to_s, :inspect
  end
end
