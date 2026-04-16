# frozen_string_literal: true

# YAML nested invalidation cascade: invalidate a nested node inside a
# definition_path-based sub-workflow, then rerun that branch on the next call.
#
# Run: ruby -Ilib examples/yaml_nested_invalidation_cascade.rb

require "dag"
require "tmpdir"

Dir.mktmpdir("dag-example-yaml-invalidation") do |dir|
  transform_count = File.join(dir, "transform.count")
  publish_count = File.join(dir, "publish.count")

  child_path = File.join(dir, "child.yml")
  File.write(child_path, <<~YAML)
    nodes:
      transform:
        type: exec
        command: 'ruby -e "path = ARGV.fetch(0); count = (File.exist?(path) ? File.read(path).to_i : 0) + 1; File.write(path, count); print %{transform-\#{count}}" #{transform_count}'
      publish:
        type: exec
        depends_on: [transform]
        command: 'ruby -e "path = ARGV.fetch(0); count = (File.exist?(path) ? File.read(path).to_i : 0) + 1; File.write(path, count); print %{publish-\#{count}}" #{publish_count}'
  YAML

  parent_path = File.join(dir, "parent.yml")
  File.write(parent_path, <<~YAML)
    nodes:
      process:
        type: sub_workflow
        definition_path: child.yml
        resume_key: process-v1
        output_key: publish
  YAML

  parent = DAG::Workflow::Loader.from_file(parent_path)
  store = DAG::Workflow::ExecutionStore::MemoryStore.new

  first = DAG::Workflow::Runner.new(parent,
    parallel: false,
    workflow_id: "example-yaml-nested-invalidation",
    execution_store: store).call

  invalidated = DAG::Workflow.invalidate(
    workflow_id: "example-yaml-nested-invalidation",
    node: [:process, :transform],
    definition: parent,
    execution_store: store
  )

  second = DAG::Workflow::Runner.new(parent,
    parallel: false,
    workflow_id: "example-yaml-nested-invalidation",
    execution_store: store).call

  puts "=== First Run ==="
  puts "Process output: #{first.outputs[:process].value}"
  puts "=== Invalidate YAML nested node ==="
  puts "Invalidated nodes: #{invalidated.sort_by { |path| path.map(&:to_s) }.inspect}"
  puts "=== Second Run ==="
  puts "Process output: #{second.outputs[:process].value}"
  puts "Transform calls: #{File.read(transform_count).strip}"
  puts "Publish calls: #{File.read(publish_count).strip}"
end
