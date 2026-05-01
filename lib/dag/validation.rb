# frozen_string_literal: true

module DAG
  # Small internal validation helpers shared by value objects and adapters.
  # They intentionally keep messages explicit at call sites via `label`.
  # @api private
  module Validation
    module_function

    # @param value [Object]
    # @param label [String]
    # @return [Array]
    def array!(value, label)
      raise ArgumentError, "#{label} must be an Array" unless value.is_a?(Array)

      value
    end

    # @param value [Object]
    # @param label [String]
    # @return [Hash]
    def hash!(value, label)
      raise ArgumentError, "#{label} must be a Hash" unless value.is_a?(Hash)

      value
    end

    # @param value [Object]
    # @param label [String]
    # @return [Hash, nil]
    def optional_hash!(value, label)
      return value if value.nil? || value.is_a?(Hash)

      raise ArgumentError, "#{label} must be Hash or nil"
    end

    # @param value [Object]
    # @param label [String]
    # @return [String]
    def string!(value, label)
      raise ArgumentError, "#{label} must be String" unless value.is_a?(String)

      value
    end

    # @param value [Object]
    # @param label [String]
    # @return [String]
    def nonempty_string!(value, label)
      string!(value, label)
      raise ArgumentError, "#{label} must not be empty" if value.empty?

      value
    end

    # @param value [Object]
    # @param label [String]
    # @return [Symbol]
    def symbol!(value, label)
      raise ArgumentError, "#{label} must be Symbol" unless value.is_a?(Symbol)

      value
    end

    # @param value [Object]
    # @param label [String]
    # @param message [String, nil]
    # @return [String, Symbol]
    def string_or_symbol!(value, label, message: nil)
      return value if value.is_a?(String) || value.is_a?(Symbol)

      raise ArgumentError, message || "#{label} must be String or Symbol"
    end

    # @param value [Object]
    # @param label [String]
    # @return [Integer]
    def integer!(value, label)
      raise ArgumentError, "#{label} must be Integer" unless value.is_a?(Integer)

      value
    end

    # @param value [Object]
    # @param label [String]
    # @param message [String, nil]
    # @return [Integer, nil]
    def optional_integer!(value, label, message: nil)
      return value if value.nil? || value.is_a?(Integer)

      raise ArgumentError, message || "#{label} must be Integer or nil"
    end

    # @param value [Object]
    # @param label [String]
    # @return [Integer]
    def positive_integer!(value, label)
      unless value.is_a?(Integer) && value.positive?
        raise ArgumentError, "#{label} must be a positive Integer"
      end

      value
    end

    # @param value [Object]
    # @param label [String]
    # @return [Integer]
    def nonnegative_integer!(value, label)
      unless value.is_a?(Integer) && !value.negative?
        raise ArgumentError, "#{label} must be a non-negative Integer"
      end

      value
    end

    # @param value [Object]
    # @param label [String]
    # @return [Boolean]
    def boolean!(value, label)
      return value if value == true || value == false

      raise ArgumentError, "#{label} must be true or false"
    end

    # @param value [Object]
    # @param klass [Class, Module]
    # @param label [String]
    # @param message [String, nil]
    # @return [Object]
    def instance!(value, klass, label, message: nil)
      return value if value.is_a?(klass)

      raise ArgumentError, message || "#{label} must be #{klass}"
    end

    # @param value [Object]
    # @param klass [Class, Module]
    # @param label [String]
    # @param message [String, nil]
    # @return [Object, nil]
    def optional_instance!(value, klass, label, message: nil)
      return value if value.nil? || value.is_a?(klass)

      raise ArgumentError, message || "#{label} must be #{klass} or nil"
    end

    # @param value [Object]
    # @param allowed [#include?]
    # @param label [String]
    # @param message [String, nil]
    # @return [Object]
    def member!(value, allowed, label, message: nil)
      return value if allowed.include?(value)

      raise ArgumentError, message || "#{label} must be one of #{allowed.inspect}"
    end

    # @param value [Object]
    # @return [Integer]
    def revision!(value)
      positive_integer!(value, "revision")
    end

    # @param value [Object]
    # @return [String, Symbol]
    def node_id!(value)
      return value if value.is_a?(Symbol) || value.is_a?(String)

      raise ArgumentError, "node_id must be Symbol or String"
    end

    # @param value [Object]
    # @param method_name [Symbol]
    # @param label [String]
    # @return [Object]
    def dependency!(value, method_name, label)
      return value if value.respond_to?(method_name)

      raise ArgumentError, "#{label} must respond to #{method_name}"
    end
  end
end
