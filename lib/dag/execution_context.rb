# frozen_string_literal: true

module DAG
  # Deep-frozen, copy-on-write hash wrapper used as the kernel's
  # ExecutionContext. Keys and values must be JSON-safe — `from(...)` and
  # `merge(...)` enforce `DAG.json_safe!` and deep-freeze the result.
  class ExecutionContext
    def self.from(hash)
      new(hash || {})
    end

    def initialize(hash)
      DAG.json_safe!(hash, "$root")
      @data = DAG.deep_freeze(DAG.deep_dup(hash))
      freeze
    end

    def merge(patch)
      patch ||= {}
      DAG.json_safe!(patch, "$patch")
      ExecutionContext.new(@data.merge(DAG.deep_dup(patch)))
    end

    def fetch(key, *default, &block)
      @data.fetch(key, *default, &block)
    end

    def dig(*keys) = @data.dig(*keys)
    def [](key) = @data[key]
    def key?(key) = @data.key?(key)
    def empty? = @data.empty?
    def size = @data.size
    def keys = @data.keys
    def each(&block) = @data.each(&block)

    # Returns a fresh deep-dup, never the internal frozen hash.
    def to_h
      DAG.deep_dup(@data)
    end

    def ==(other)
      other.is_a?(ExecutionContext) && @data == other.instance_variable_get(:@data)
    end
    alias_method :eql?, :==

    def hash = @data.hash

    def inspect = "#<DAG::ExecutionContext keys=#{@data.keys}>"
    alias_method :to_s, :inspect
  end
end
