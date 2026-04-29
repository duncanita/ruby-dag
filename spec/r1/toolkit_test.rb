# frozen_string_literal: true

require_relative "../test_helper"

class ToolkitTest < Minitest::Test
  def test_in_memory_kit_returns_frozen_kit_with_runner_storage_and_event_bus
    kit = DAG::Toolkit.in_memory_kit(registry: default_test_registry)

    assert_instance_of DAG::Toolkit::Kit, kit
    assert kit.frozen?
    assert_instance_of DAG::Runner, kit.runner
    assert_instance_of DAG::Adapters::Memory::Storage, kit.storage
    assert_instance_of DAG::Adapters::Memory::EventBus, kit.event_bus
  end

  def test_in_memory_kit_wires_stdlib_ports_into_runner
    kit = DAG::Toolkit.in_memory_kit(registry: default_test_registry)

    assert_same kit.storage, kit.runner.storage
    assert_same kit.event_bus, kit.runner.event_bus
    assert_instance_of DAG::Adapters::Stdlib::Clock, kit.runner.clock
    assert_instance_of DAG::Adapters::Stdlib::IdGenerator, kit.runner.id_generator
    assert_instance_of DAG::Adapters::Stdlib::Fingerprint, kit.runner.fingerprint
    assert_instance_of DAG::Adapters::Stdlib::Serializer, kit.runner.serializer
  end

  def test_in_memory_kit_runs_the_quick_start_definition_to_completion
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    registry.freeze!

    kit = DAG::Toolkit.in_memory_kit(registry: registry)
    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_edge(:a, :b)

    id = kit.runner.id_generator.call
    kit.storage.create_workflow(
      id: id,
      initial_definition: definition,
      initial_context: {hello: "world"},
      runtime_profile: DAG::RuntimeProfile.default
    )

    assert_equal :completed, kit.runner.call(id).state
  end

  def test_in_memory_kit_requires_registry
    assert_raises(ArgumentError) { DAG::Toolkit.in_memory_kit }
  end
end
