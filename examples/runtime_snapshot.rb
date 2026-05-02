# frozen_string_literal: true

require "ruby-dag"

class RuntimeSnapshotSourceStep < DAG::Step::Base
  def call(_input)
    DAG::Success[value: {message: "hello"}, context_patch: {source_value: "hello"}]
  end
end

class RuntimeSnapshotInspectStep < DAG::Step::Base
  def call(input)
    snapshot = input.runtime_snapshot
    source = snapshot.predecessors.fetch(:source).fetch(:value).fetch(:message)

    puts "workflow_id=#{snapshot.workflow_id}"
    puts "revision=#{snapshot.revision}"
    puts "node_id=#{snapshot.node_id}"
    puts "attempt_number=#{snapshot.attempt_number}"
    puts "predecessor_source=#{source}"
    puts "context_source=#{input.context[:source_value]}"
    puts "effect_count=#{snapshot.effects.size}"

    DAG::Success[value: :inspected, context_patch: {}]
  end
end

registry = DAG::StepTypeRegistry.new
registry.register(name: :source, klass: RuntimeSnapshotSourceStep, fingerprint_payload: {v: 1})
registry.register(name: :inspect, klass: RuntimeSnapshotInspectStep, fingerprint_payload: {v: 1})
registry.freeze!

kit = DAG::Toolkit.in_memory_kit(registry: registry)
definition = DAG::Workflow::Definition.new
  .add_node(:source, type: :source)
  .add_node(:inspect, type: :inspect)
  .add_edge(:source, :inspect)

workflow_id = kit.runner.id_generator.call
kit.storage.create_workflow(
  id: workflow_id,
  initial_definition: definition,
  initial_context: {},
  runtime_profile: DAG::RuntimeProfile.default
)

result = kit.runner.call(workflow_id)
puts "workflow_state=#{result.state}"
