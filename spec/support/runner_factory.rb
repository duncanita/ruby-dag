# frozen_string_literal: true

module RunnerFactory
  def build_runner(storage:, event_bus: nil, registry: nil, clock: nil,
    id_generator: nil, fingerprint: nil, serializer: nil)
    DAG::Runner.new(
      storage: storage,
      event_bus: event_bus || DAG::Adapters::Null::EventBus.new,
      registry: registry || default_test_registry,
      clock: clock || DAG::Adapters::Stdlib::Clock.new,
      id_generator: id_generator || DAG::Adapters::Stdlib::IdGenerator.new,
      fingerprint: fingerprint || DAG::Adapters::Stdlib::Fingerprint.new,
      serializer: serializer || DAG::Adapters::Stdlib::Serializer.new
    )
  end

  def default_test_registry
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    registry.register(name: :noop, klass: DAG::BuiltinSteps::Noop, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end
end
