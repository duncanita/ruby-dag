# frozen_string_literal: true

module DAG
  # Deep-frozen, copy-on-write hash wrapper used as the kernel's
  # ExecutionContext. Keys and values must be JSON-safe — `from(...)` and
  # `merge(...)` enforce `DAG.json_safe!` and deep-freeze the result.
  # @api public
  class ExecutionContext
    # Build an ExecutionContext from a (possibly nil) hash.
    # @param hash [Hash, nil]
    # @return [ExecutionContext]
    def self.from(hash)
      new(hash || {})
    end

    # @param hash [Hash] JSON-safe payload
    def initialize(hash)
      DAG.json_safe!(hash, "$root")
      @data = DAG.frozen_copy(hash)
      freeze
    end

    # Returns a new ExecutionContext with `patch` keys merged on top.
    # `nil` or empty patch returns `self` unchanged.
    # @param patch [Hash, nil]
    # @return [ExecutionContext]
    def merge(patch)
      return self if patch.nil? || patch.empty?
      ExecutionContext.new(@data.merge(patch))
    end

    # @return [Object] underlying value, or default per Hash#fetch
    def fetch(key, *default, &block)
      @data.fetch(key, *default, &block)
    end

    # @return [Object, nil]
    def dig(*keys) = @data.dig(*keys)

    # @return [Object, nil]
    def [](key) = @data[key]

    # @return [Boolean]
    def key?(key) = @data.key?(key)

    # @return [Boolean]
    def empty? = @data.empty?

    # @return [Integer]
    def size = @data.size

    # @return [Array]
    def keys = @data.keys

    # Iterate `key, value` pairs.
    def each(&block) = @data.each(&block)

    # Returns a fresh deep-dup, never the internal frozen hash.
    # @return [Hash]
    def to_h
      DAG.deep_dup(@data)
    end

    # @return [Boolean]
    def ==(other)
      other.is_a?(ExecutionContext) && @data == other.instance_variable_get(:@data)
    end
    alias_method :eql?, :==

    # @return [Integer]
    def hash = @data.hash

    # @return [String]
    def inspect = "#<DAG::ExecutionContext keys=#{@data.keys}>"
    alias_method :to_s, :inspect
  end
end
