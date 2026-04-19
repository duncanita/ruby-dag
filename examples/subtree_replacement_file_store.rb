# frozen_string_literal: true

# Dynamic graph mutation with a file-backed execution store across fresh store
# instances.
#
# Run: ruby -Ilib examples/subtree_replacement_file_store.rb

require "dag"
require "tmpdir"

source_calls = 0
process_calls = 0
normalize_calls = 0
summarize_calls = 0
report_calls = 0

original = DAG::Workflow::Loader.from_hash(
  source: {
    type: :ruby,
    resume_key: "source-v1",
    callable: ->(_input) do
      source_calls += 1
      DAG::Success.new(value: "payload")
    end
  },
  process: {
    type: :ruby,
    depends_on: [:source],
    resume_key: "process-v1",
    callable: ->(input) do
      process_calls += 1
      DAG::Success.new(value: input[:source].upcase)
    end
  },
  report: {
    type: :ruby,
    depends_on: [:process],
    resume_key: "report-v1",
    callable: ->(input) do
      report_calls += 1
      DAG::Success.new(value: "report:#{input[:process]}:v#{report_calls}")
    end
  }
)

replacement = DAG::Workflow::Loader.from_hash(
  normalize: {
    type: :ruby,
    resume_key: "normalize-v1",
    callable: ->(input) do
      normalize_calls += 1
      DAG::Success.new(value: "#{input[:source]}-normalized")
    end
  },
  summarize: {
    type: :ruby,
    depends_on: [:normalize],
    resume_key: "summarize-v1",
    callable: ->(input) do
      summarize_calls += 1
      DAG::Success.new(value: input[:normalize].upcase)
    end
  }
)

mutated = DAG::Workflow.replace_subtree(
  original,
  root_node: :process,
  replacement: replacement,
  reconnect: [{from: :summarize, to: :report, metadata: {as: :process}}]
)

Dir.mktmpdir("dag-subtree-replacement-file-store") do |dir|
  first_store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
  second_store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)
  third_store = DAG::Workflow::ExecutionStore::FileStore.new(dir: dir)

  first = DAG::Workflow::Runner.new(original,
    parallel: false,
    workflow_id: "example-subtree-file-store",
    execution_store: first_store).call

  impact = DAG::Workflow.apply_subtree_replacement_impact(
    workflow_id: "example-subtree-file-store",
    definition: original,
    root_node: :process,
    execution_store: second_store,
    cause: {source: :planner},
    new_definition: mutated
  )

  second = DAG::Workflow::Runner.new(mutated,
    parallel: false,
    workflow_id: "example-subtree-file-store",
    execution_store: third_store).call

  puts "=== First Run (file store) ==="
  puts "Initial source: #{first.outputs[:source].value}"
  puts "Initial report: #{first.outputs[:report].value}"
  puts
  puts "=== Mutation Impact Applied ==="
  puts "Obsolete nodes: #{impact[:obsolete_nodes].inspect}"
  puts "Stale nodes: #{impact[:stale_nodes].inspect}"
  puts
  puts "=== Second Run (mutated definition, fresh store instance) ==="
  puts "Final source: #{second.outputs[:source].value}"
  puts "Final summarize: #{second.outputs[:summarize].value}"
  puts "Final report: #{second.outputs[:report].value}"
  puts "Source reused calls: #{source_calls}"
  puts "Process calls: #{process_calls}"
  puts "Normalize calls: #{normalize_calls}"
  puts "Summarize calls: #{summarize_calls}"
  puts "Report calls: #{report_calls}"
end
