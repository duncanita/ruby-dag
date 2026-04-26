# frozen_string_literal: true

module DAG
  # Maps a step-type symbol (e.g. `:passthrough`) to its implementing class
  # plus a deterministic `fingerprint_payload` Hash. Re-registering the same
  # name with the same payload is a no-op; re-registering with a different
  # payload raises `FingerprintMismatchError`.
  #
  # Call `freeze!` after registration is complete. Looking up an unknown
  # name raises `UnknownStepTypeError`.
  class StepTypeRegistry
    Entry = Data.define(:klass, :fingerprint_payload, :config)

    def initialize
      @entries = {}
    end

    def register(name:, klass:, fingerprint_payload:, config: {})
      raise FrozenError, "registry is frozen" if frozen?
      raise ArgumentError, "name must be a Symbol" unless name.is_a?(Symbol)
      raise ArgumentError, "klass must implement StepProtocol" unless StepProtocol.implements?(klass)
      DAG.json_safe!(fingerprint_payload, "$root.fingerprint_payload")

      new_entry = Entry.new(
        klass: klass,
        fingerprint_payload: DAG.frozen_copy(fingerprint_payload),
        config: DAG.frozen_copy(config)
      )

      existing = @entries[name]
      if existing
        if existing.klass == klass && existing.fingerprint_payload == new_entry.fingerprint_payload
          return self
        end
        raise FingerprintMismatchError,
          "step type #{name.inspect} already registered with a different fingerprint"
      end

      @entries[name] = new_entry
      self
    end

    def lookup(name)
      sym = name.to_sym
      entry = @entries[sym]
      raise UnknownStepTypeError, "Unknown step type: #{sym.inspect}" unless entry
      entry
    end

    def registered?(name) = @entries.key?(name.to_sym)
    def names = @entries.keys

    def freeze!
      @entries.freeze
      freeze
    end
  end
end
