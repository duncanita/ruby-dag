# frozen_string_literal: true

module DAG
  # Convenience factory that wires the stdlib adapters and an in-memory
  # storage + event bus into a `DAG::Runner`. Intended for examples,
  # tests, and quick-start scripts; production callers should construct
  # the seven ports explicitly so that production-grade adapters can be
  # injected.
  #
  # @api public
  module Toolkit
    # The bundle returned by {Toolkit.in_memory_kit}. The runner exposes
    # the four stdlib ports through its own attribute readers, so callers
    # can reach the id generator via `kit.runner.id_generator.call`.
    Kit = Data.define(:runner, :storage, :event_bus)

    # Build a frozen {Kit} containing a {Runner} wired to:
    #
    # - {Adapters::Memory::Storage} for durable kernel state
    # - {Adapters::Memory::EventBus} for live event delivery
    # - {Adapters::Stdlib::Clock}, {Adapters::Stdlib::IdGenerator},
    #   {Adapters::Stdlib::Fingerprint}, and {Adapters::Stdlib::Serializer}
    #
    # @param registry [DAG::StepTypeRegistry] frozen registry of step types
    # @return [Kit] frozen bundle
    # @api public
    def self.in_memory_kit(registry:)
      storage = Adapters::Memory::Storage.new
      event_bus = Adapters::Memory::EventBus.new
      runner = Runner.new(
        storage: storage,
        event_bus: event_bus,
        registry: registry,
        clock: Adapters::Stdlib::Clock.new,
        id_generator: Adapters::Stdlib::IdGenerator.new,
        fingerprint: Adapters::Stdlib::Fingerprint.new,
        serializer: Adapters::Stdlib::Serializer.new
      )
      Kit.new(runner: runner, storage: storage, event_bus: event_bus).freeze
    end
  end
end
