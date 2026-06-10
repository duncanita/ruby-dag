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

    # Internal fast path used by `merge`: `data` is already deep-frozen and
    # JSON-safe, so re-walking the whole context per merge (which the Runner
    # does once per predecessor per attempt) would prove nothing new.
    # @api private
    def self.trusted(data, canonical_keys)
      context = allocate
      context.instance_variable_set(:@data, data)
      context.instance_variable_set(:@canonical_keys, canonical_keys)
      context.freeze
    end
    private_class_method :trusted

    # @param hash [Hash] JSON-safe payload
    def initialize(hash)
      DAG.json_safe!(hash)
      @data = DAG.frozen_copy(hash)
      @canonical_keys = Set.new(@data.keys.map(&:to_s)).freeze
      freeze
    end

    # Returns a new ExecutionContext with `patch` keys merged on top.
    # `nil` or empty patch returns `self` unchanged. Only the patch is
    # validated and copied; the existing data is already deep-frozen.
    # @param patch [Hash, nil]
    # @return [ExecutionContext]
    # @raise [ArgumentError] when a patch key collides canonically (Symbol
    #   vs String spelling of the same key) with an existing key
    def merge(patch)
      return self if patch.nil? || patch.empty?

      DAG.json_safe!(patch)
      copied = DAG.frozen_copy(patch)
      added_keys = validate_patch_keys!(copied)
      merged_keys = added_keys.empty? ? @canonical_keys : (@canonical_keys | added_keys).freeze
      ExecutionContext.send(:trusted, @data.merge(copied).freeze, merged_keys)
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
    def inspect = "#<DAG::ExecutionContext keys=#{keys}>"
    alias_method :to_s, :inspect

    private

    # A patch key that equals an existing key (same object class) is a plain
    # overwrite; a patch key whose canonical String form matches an existing
    # key under a different spelling would silently fork the value, so it is
    # rejected exactly like `DAG.json_safe!` rejects it within one hash.
    def validate_patch_keys!(copied)
      copied.keys.filter_map { |key|
        next if @data.key?(key)

        canonical = key.to_s
        if @canonical_keys.include?(canonical)
          raise ArgumentError, "canonical key collision at $root: #{canonical.inspect}"
        end
        canonical
      }
    end
  end
end
