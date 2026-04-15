# frozen_string_literal: true

# YAML-safe schedule metadata round-trip: dump a workflow with schedule metadata,
# load it back, and run it against a fake clock.
#
# Run: ruby -Ilib examples/schedule_metadata_roundtrip.rb

require "dag"
require "tmpdir"
require "yaml"

clock = Struct.new(:wall_time, :mono_time) do
  def wall_now = wall_time
  def monotonic_now = mono_time
  def advance(seconds) = self.wall_time += seconds
end.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)

definition = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :exec,
    command: "printf payload",
    schedule: {
      not_before: Time.utc(2026, 4, 15, 10, 0, 0),
      not_after: Time.utc(2026, 4, 15, 11, 0, 0),
      ttl: 3600,
      cron: "0 * * * *"
    }
  }
)

Dir.mktmpdir("dag-schedule-roundtrip") do |dir|
  path = File.join(dir, "workflow.yml")
  DAG::Workflow::Dumper.to_file(definition, path)

  raw_schedule = YAML.safe_load_file(path).fetch("nodes").fetch("fetch").fetch("schedule")
  loaded = DAG::Workflow::Loader.from_file(path)
  loaded_schedule = loaded.step(:fetch).config[:schedule]

  first = DAG::Workflow::Runner.new(loaded,
    parallel: false,
    clock: clock).call

  clock.advance(3600)

  second = DAG::Workflow::Runner.new(loaded,
    parallel: false,
    clock: clock).call

  puts "=== Dumped Schedule Metadata ==="
  puts raw_schedule.inspect
  puts "=== Loaded Schedule Metadata ==="
  puts loaded_schedule.inspect
  puts "=== First Run ==="
  puts "Status: #{first.status}"
  puts "=== Second Run ==="
  puts "Status: #{second.status}"
  puts "Output: #{second.outputs[:fetch].value}"
end
