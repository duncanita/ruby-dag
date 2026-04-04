# frozen_string_literal: true

module DAG
  Success = Data.define(:value) do
    include Result

    def success? = true
    def failure? = false
    def error = nil

    def and_then = yield(value)
    def map = Success.new(value: yield(value))
    def map_error = self
    def unwrap! = value
    def value_or(_default) = value
    def to_h = {status: :success, value: value}
    def inspect = "Success(#{value.inspect})"
    alias_method :to_s, :inspect
  end
end
