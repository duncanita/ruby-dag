# frozen_string_literal: true

# Sub-workflow composition: a parent step can execute a child Definition,
# flatten child trace entries, and optionally persist child outputs under the
# parent node path.
#
# Run: ruby -Ilib examples/sub_workflow.rb

require "dag"

child_calls = 0
child_definition = DAG::Workflow::Loader.from_hash(
  analyze: {
    type: :ruby,
    resume_key: "analyze-v1",
    callable: ->(input) { DAG::Success.new(value: input[:raw].upcase) }
  },
  summarize: {
    type: :ruby,
    depends_on: [:analyze],
    resume_key: "summarize-v1",
    callable: ->(input, context) do
      child_calls += 1
      DAG::Success.new(value: "#{input[:analyze]}#{context[:suffix]}")
    end
  }
)

parent_definition = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :ruby,
    resume_key: "fetch-v1",
    callable: ->(_input) { DAG::Success.new(value: "hello") }
  },
  process: {
    type: :sub_workflow,
    definition: child_definition,
    depends_on: [:fetch],
    input_mapping: {fetch: :raw},
    output_key: :summarize,
    resume_key: "process-v1"
  }
)

puts "=== Parent Workflow ==="
parent_result = DAG::Workflow::Runner.new(parent_definition,
  parallel: false,
  context: {suffix: "!"}).call
puts "Status: #{parent_result.status}"
puts "Output: #{parent_result.outputs[:process].value}"
puts "Trace names: #{parent_result.trace.map(&:name).inspect}"
puts

puts "=== Durable Run ==="
child_calls = 0
store = DAG::Workflow::ExecutionStore::MemoryStore.new
runner = lambda do
  DAG::Workflow::Runner.new(parent_definition,
    parallel: false,
    context: {suffix: "!"},
    workflow_id: "example-sub-workflow",
    execution_store: store)
end

first = runner.call.call
second = runner.call.call
puts "First output: #{first.outputs[:process].value}"
puts "Second output: #{second.outputs[:process].value}"
puts "Child calls: #{child_calls}"
puts "Stored child output: #{store.load_output(workflow_id: "example-sub-workflow", node_path: [:process, :summarize])[:result].value}"
