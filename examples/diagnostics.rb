# frozen_string_literal: true

require "ruby-dag"

registry = DAG::StepTypeRegistry.new
registry.register(
  name: :passthrough,
  klass: DAG::BuiltinSteps::Passthrough,
  fingerprint_payload: {v: 1}
)
registry.freeze!

kit = DAG::Toolkit.in_memory_kit(registry: registry)
definition = DAG::Workflow::Definition.new.add_node(:inspect, type: :passthrough)
workflow_id = kit.runner.id_generator.call
kit.storage.create_workflow(
  id: workflow_id,
  initial_definition: definition,
  initial_context: {source: "diagnostics-example"},
  runtime_profile: DAG::RuntimeProfile.default
)

kit.runner.call(workflow_id)

trace = DAG::Diagnostics.trace_records(storage: kit.storage, workflow_id: workflow_id)
diagnostics = DAG::Diagnostics.node_diagnostics(storage: kit.storage, workflow_id: workflow_id)
node = diagnostics.fetch(0)

puts "trace_events=#{trace.map(&:event_type).join(",")}"
puts "trace_statuses=#{trace.map(&:status).join(",")}"
puts "node_id=#{node.node_id}"
puts "node_state=#{node.state}"
puts "attempt_count=#{node.attempt_count}"
puts "effects_terminal=#{node.effects_terminal.inspect}"
