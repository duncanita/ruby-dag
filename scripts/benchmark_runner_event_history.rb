# frozen_string_literal: true

require "securerandom"
require File.join(ENV.fetch("DAG_LIB_ROOT", File.expand_path("../lib", __dir__)), "dag")

registry = DAG::StepTypeRegistry.new.freeze!
kit = DAG::Toolkit.in_memory_kit(registry: registry)
definition = DAG::Workflow::Definition.new
profile = DAG::RuntimeProfile.default

[0, 1_000, 5_000].product([:call, :resume]).each do |history_size, method|
  workflow_id = SecureRandom.uuid
  kit.storage.create_workflow(id: workflow_id, initial_definition: definition,
    initial_context: {}, runtime_profile: profile)
  history_size.times do
    event = DAG::Event[type: :mutation_applied, workflow_id: workflow_id,
      revision: 1, at_ms: 0, payload: {blob: "x" * 128}]
    kit.storage.append_event(workflow_id: workflow_id, event: event)
  end
  kit.storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused) if method == :resume

  GC.start
  before_allocations = GC.stat(:total_allocated_objects)
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  kit.runner.public_send(method, workflow_id)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  allocations = GC.stat(:total_allocated_objects) - before_allocations
  puts "method=#{method} events=#{history_size} elapsed_ms=#{(elapsed * 1000).round(2)} allocations=#{allocations}"
end
