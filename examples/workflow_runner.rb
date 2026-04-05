# frozen_string_literal: true

# Workflow execution: defining steps, running pipelines, using callbacks.
#
# Run: ruby -Ilib examples/workflow_runner.rb

require "dag"

# --- Manual workflow construction ---

puts "=== Manual Workflow ==="

graph = DAG::Graph.new
  .add_node(:greet)
  .add_node(:shout)
  .add_edge(:greet, :shout)

registry = DAG::Workflow::Registry.new
registry.register(DAG::Workflow::Step.new(name: :greet, type: :exec, command: 'echo "hello world"'))
registry.register(DAG::Workflow::Step.new(name: :shout, type: :ruby,
  callable: ->(input) { DAG::Success(input.upcase) }))

definition = DAG::Workflow::Definition.new(graph: graph, registry: registry)

puts "Definition: #{definition.inspect}"
puts "Steps: #{definition.steps.map(&:to_s)}"
puts "Empty? #{definition.empty?}"
puts "Execution order: #{definition.execution_order.inspect}"

result = DAG::Workflow::Runner.new(definition.graph, definition.registry, parallel: false).call

puts "Success? #{result.success?}"
puts "Output:  #{result.value[:shout].value}"
puts

# --- Loading from YAML ---

puts "=== YAML Workflow ==="

yaml = <<~YAML
  name: example
  nodes:
    fetch:
      type: exec
      command: 'echo "raw data: 42"'
    process:
      type: exec
      command: 'echo "processed"'
      depends_on: [fetch]
    report:
      type: exec
      command: 'echo "done"'
      depends_on: [process]
YAML

definition = DAG::Workflow::Loader.from_yaml(yaml)
puts "Loaded: #{definition.inspect}"
puts "Layers: #{definition.execution_order.inspect}"

result = DAG::Workflow::Runner.new(definition.graph, definition.registry, parallel: false).call
puts "Success? #{result.success?}"
result.value.each do |name, step_result|
  puts "  #{name}: #{step_result.value}"
end
puts

# --- Callbacks ---

puts "=== Callbacks ==="

definition = DAG::Workflow::Loader.from_yaml(<<~YAML)
  name: callback-demo
  nodes:
    step_a:
      type: exec
      command: 'echo "A done"'
    step_b:
      type: exec
      command: 'echo "B done"'
      depends_on: [step_a]
YAML

runner = DAG::Workflow::Runner.new(definition.graph, definition.registry, parallel: false,
  on_step_start: ->(name, step) { puts "  START #{name} (#{step.type})" },
  on_step_finish: ->(name, result) { puts "  DONE  #{name} => #{result.success? ? "ok" : "FAIL"}" })

runner.call
puts

# --- Failure handling ---

puts "=== Failure Handling ==="

definition = DAG::Workflow::Loader.from_yaml(<<~YAML)
  name: fail-demo
  nodes:
    good:
      type: exec
      command: 'echo "works"'
    bad:
      type: exec
      command: 'exit 1'
      depends_on: [good]
    never:
      type: exec
      command: 'echo "skipped"'
      depends_on: [bad]
YAML

result = DAG::Workflow::Runner.new(definition.graph, definition.registry, parallel: false).call
puts "Success? #{result.success?}"
puts "Failed step: #{result.error[:failed_node]}"
puts "Completed: #{result.error[:outputs].keys}"
puts

# --- Planner ---

puts "=== Planner ==="

graph = DAG::Graph::Builder.build do |b|
  b.add_node(:a)
  b.add_node(:b)
  b.add_node(:c)
  b.add_node(:d)
  b.add_edge(:a, :b)
  b.add_edge(:a, :c)
  b.add_edge(:b, :d)
  b.add_edge(:c, :d)
end

planner = DAG::Graph::Planner.new(graph)
puts "Layers: #{planner.layers.inspect}"
puts "Flat order: #{planner.flat_order.inspect}"
planner.each_layer.with_index(1) do |layer, i|
  puts "  Layer #{i}: #{layer.inspect} (#{layer.size} parallel)"
end
