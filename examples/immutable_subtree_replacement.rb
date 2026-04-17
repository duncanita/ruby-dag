# frozen_string_literal: true

# Immutable graph mutation: derive a new definition by replacing one workflow
# node with a new subgraph, while leaving the original definition untouched.
#
# Run: ruby -Ilib examples/immutable_subtree_replacement.rb

require "dag"

original = DAG::Workflow::Loader.from_hash(
  source: {
    type: :ruby,
    callable: ->(_input) { DAG::Success.new(value: "payload") }
  },
  config: {
    type: :ruby,
    callable: ->(_input) { DAG::Success.new(value: "v1") }
  },
  process: {
    type: :ruby,
    depends_on: [:source],
    callable: ->(input) { DAG::Success.new(value: input[:source].upcase) }
  },
  report: {
    type: :ruby,
    depends_on: [{from: :process, as: :summary}, :config],
    callable: ->(input) { DAG::Success.new(value: "report:#{input[:summary]}|#{input[:config]}") }
  }
)

replacement = DAG::Workflow::Loader.from_hash(
  normalize: {
    type: :ruby,
    callable: ->(input) { DAG::Success.new(value: "#{input[:source]}-normalized") }
  },
  summarize: {
    type: :ruby,
    depends_on: [:normalize],
    callable: ->(input) { DAG::Success.new(value: input[:normalize].upcase) }
  }
)

mutated = DAG::Workflow.replace_subtree(
  original,
  root_node: :process,
  replacement: replacement,
  reconnect: [{from: :summarize, to: :report, metadata: {as: :summary}}]
)

original_result = DAG::Workflow::Runner.new(original, parallel: false).call
mutated_result = DAG::Workflow::Runner.new(mutated, parallel: false).call

puts "=== Original Definition ==="
puts "Original output: report:#{original_result.outputs[:process].value}"
puts
puts "=== Mutated Definition ==="
puts "Mutated output: #{mutated_result.outputs[:report].value}"
puts "Original still has process? #{original.graph.node?(:process)}"
puts "Mutated has process? #{mutated.graph.node?(:process)}"
puts "Mutated has summarize? #{mutated.graph.node?(:summarize)}"
