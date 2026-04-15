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
  callable: ->(input) { DAG::Success.new(value: input[:greet].upcase) }))

definition = DAG::Workflow::Definition.new(graph: graph, registry: registry)

puts "Definition: #{definition}"
puts "Steps: #{definition.steps.map(&:to_s)}"
puts "Empty? #{definition.empty?}"
puts "Execution order: #{definition.execution_order.inspect}"

result = DAG::Workflow::Runner.new(definition.graph, definition.registry, parallel: false).call

puts "Success? #{result.success?}"
puts "Output:  #{result.outputs[:shout].value}"
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
puts "Loaded: #{definition}"
puts "Layers: #{definition.execution_order.inspect}"

result = DAG::Workflow::Runner.new(definition.graph, definition.registry, parallel: false).call
puts "Success? #{result.success?}"
result.outputs.each do |name, step_result|
  puts "  #{name}: #{step_result.value}"
end
puts

# --- Programmatic workflow with from_hash ---

puts "=== from_hash Workflow ==="

definition = DAG::Workflow::Loader.from_hash(
  fetch: {type: :exec, command: 'echo "fetched"'},
  transform: {type: :exec, command: 'echo "transformed"', depends_on: [:fetch], timeout: 30},
  store: {type: :exec, command: 'echo "stored"', depends_on: [:transform]}
)

puts "Loaded: #{definition}"
puts "Layers: #{definition.execution_order.inspect}"
puts "Transform config: #{definition.step(:transform).config.inspect}"
puts

# --- Dumper (round-trip) ---

puts "=== Dumper ==="
yaml_out = DAG::Workflow::Dumper.to_yaml(definition)
puts yaml_out
puts "Round-trip equal? #{DAG::Workflow::Loader.from_yaml(yaml_out).execution_order == definition.execution_order}"
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
puts "Completed: #{result.outputs.keys}"
puts

# --- Result monad ---

puts "=== Result Monad ==="

success = DAG::Success.new(value: "hello")
failure = DAG::Failure.new(error: "oops")

puts "Success: #{success.inspect}"
puts "Failure: #{failure.inspect}"
puts

# map transforms the value inside a Success
puts "map:       #{success.map { |v| v.upcase }.inspect}"
puts "map fail:  #{failure.map { |v| v.upcase }.inspect}"
puts

# and_then chains computations (returns a new Result)
chained = success.and_then { |v| DAG::Success.new(value: "#{v} world") }
puts "and_then:       #{chained.inspect}"
puts "and_then fail:  #{failure.and_then { |v| DAG::Success.new(value: "#{v} world") }.inspect}"
puts

# recover lets a Failure produce a fresh Result on the failure side
recovered = failure.recover { |_e| DAG::Success.new(value: "default") }
puts "recover:    #{recovered.inspect}"
puts

# unwrap! returns the value on Success and raises on Failure
puts "unwrap!:    #{success.unwrap!}"
puts

# to_h for serialization
puts "Success to_h: #{success.to_h.inspect}"
puts "Failure to_h: #{failure.to_h.inspect}"
