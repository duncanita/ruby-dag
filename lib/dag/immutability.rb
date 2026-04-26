# frozen_string_literal: true

module DAG
  JSON_KEY_CLASSES = [String, Symbol].freeze
  JSON_SCALAR_CLASSES = [String, Integer, Float, TrueClass, FalseClass, NilClass, Symbol].freeze

  module_function

  # Convenience for the deep_freeze(deep_dup(...)) idiom that recurs at every
  # boundary where a value is taken from outside and stored under the
  # library's immutability discipline. Already-frozen values are returned
  # as-is — Data.define instances and other immutable values do not need
  # to be re-cloned.
  def frozen_copy(value)
    return value if value.frozen? && !value.is_a?(Hash) && !value.is_a?(Array) && !value.is_a?(String)
    deep_freeze(deep_dup(value))
  end

  def deep_freeze(value, seen = {})
    return value if immutable_scalar?(value)
    return seen[value.object_id] if seen.key?(value.object_id)

    seen[value.object_id] = value

    case value
    when Hash
      value.each do |key, nested|
        deep_freeze(key, seen)
        deep_freeze(nested, seen)
      end
    when Array
      value.each { |nested| deep_freeze(nested, seen) }
    end

    value.freeze
  end

  def deep_dup(value, seen = {})
    return value if immutable_scalar?(value)
    return seen[value.object_id] if seen.key?(value.object_id)

    case value
    when Hash
      copy = {}
      seen[value.object_id] = copy
      value.each do |key, nested|
        copy[deep_dup(key, seen)] = deep_dup(nested, seen)
      end
      copy
    when Array
      copy = []
      seen[value.object_id] = copy
      value.each { |nested| copy << deep_dup(nested, seen) }
      copy
    when String
      copy = value.dup
      seen[value.object_id] = copy
      copy
    else
      value
    end
  end

  def json_safe!(value, path = "$root")
    case value
    when Hash
      seen = {}
      value.each do |key, nested|
        unless JSON_KEY_CLASSES.any? { |klass| key.is_a?(klass) }
          raise ArgumentError, "non JSON-safe key at #{path}: #{key.class}"
        end

        canonical_key = key.to_s
        if seen.key?(canonical_key)
          raise ArgumentError, "canonical key collision at #{path}: #{canonical_key.inspect}"
        end

        seen[canonical_key] = true
        json_safe!(nested, "#{path}.#{canonical_key}")
      end
    when Array
      value.each_with_index { |nested, index| json_safe!(nested, "#{path}[#{index}]") }
    when Float
      raise ArgumentError, "non-finite float at #{path}" if value.nan? || value.infinite?
    when *JSON_SCALAR_CLASSES
      true
    else
      raise ArgumentError, "non JSON-safe value at #{path}: #{value.class}"
    end

    value
  end

  def immutable_scalar?(value)
    value.nil? || value == true || value == false ||
      value.is_a?(Symbol) || value.is_a?(Integer) || value.is_a?(Float)
  end
  private_class_method :immutable_scalar?
end
