# frozen_string_literal: true

require_relative "../test_helper"

# Mirrors the "Resume after waiting" snippet in README.md so the example
# never silently regresses against the kernel.
class ReadmeResumeExampleTest < Minitest::Test
  class GateStep < DAG::Step::Base
    GATE = []
    def call(_input)
      if GATE.any?
        DAG::Success[value: :ok]
      else
        DAG::Waiting[reason: :external_dependency]
      end
    end
  end

  def setup
    GateStep::GATE.clear
  end

  def teardown
    GateStep::GATE.clear
  end

  def test_workflow_waits_then_resumes_to_completion
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :gate, klass: GateStep, fingerprint_payload: {v: 1})
    registry.freeze!

    kit = DAG::Toolkit.in_memory_kit(registry: registry)
    definition = DAG::Workflow::Definition.new.add_node(:gate, type: :gate)
    id = kit.runner.id_generator.call
    kit.storage.create_workflow(
      id: id,
      initial_definition: definition,
      initial_context: {},
      runtime_profile: DAG::RuntimeProfile.default
    )

    assert_equal :waiting, kit.runner.call(id).state
    GateStep::GATE << :open
    kit.storage.transition_node_state(workflow_id: id, revision: 1,
      node_id: :gate, from: :waiting, to: :pending)
    assert_equal :completed, kit.runner.resume(id).state
  end
end
