# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
    minimum_coverage line: 100, branch: 100
  end
end

require "fileutils"
require "minitest/autorun"
require "securerandom"
require "tempfile"
require "tmpdir"

require_relative "../lib/dag"

TEST_TMPDIR = File.expand_path(ENV.fetch("TMPDIR", "~/.tmp/ruby-dag-tests"))
FileUtils.mkdir_p(TEST_TMPDIR)
ENV["TMPDIR"] = TEST_TMPDIR

module TestHelpers
  # Builds a Graph + Registry from a hash of node definitions.
  # Returns a Workflow::Definition.
  #
  #   build_test_workflow(
  #     a: {},
  #     b: {depends_on: [:a]},
  #     c: {type: :ruby, callable: ->(_) { DAG::Success.new(value: "ok") }}
  #   )
  def build_test_workflow(**node_defs)
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    deferred_edges = []

    node_defs.each do |name, opts|
      opts = opts.dup
      depends_on = Array(opts.delete(:depends_on))
      type = opts.delete(:type) || :exec
      opts[:command] ||= "echo #{name}" if type == :exec
      external_dependencies = []

      depends_on.each do |dep|
        descriptor = dep.is_a?(Hash) ? dep.transform_keys(&:to_sym) : {from: dep}
        if descriptor.key?(:from)
          deferred_edges << descriptor.merge(to: name)
        else
          descriptor[:workflow_id] = descriptor.delete(:workflow)
          external_dependencies << descriptor
        end
      end

      opts[:external_dependencies] = external_dependencies unless external_dependencies.empty?
      graph.add_node(name)
      registry.register(DAG::Workflow::Step.new(name: name, type: type, **opts))
    end

    deferred_edges.each do |edge|
      from = edge.fetch(:from)
      to = edge.fetch(:to)
      metadata = edge.except(:from, :to)
      graph.add_edge(from, to, **metadata)
    end

    DAG::Workflow::Definition.new(graph: graph, registry: registry)
  end

  def with_tempfile(content, suffix: ".txt", prefix: "dag_test")
    file = Tempfile.new([prefix, suffix])
    file.write(content)
    file.close
    yield file.path
  ensure
    file&.unlink
  end

  class MutableClock
    ClockState = Data.define(:wall_time, :mono_time)

    def initialize(wall_time:, mono_time:)
      @state = ClockState.new(wall_time: wall_time, mono_time: mono_time)
    end

    def wall_now = @state.wall_time
    def monotonic_now = @state.mono_time

    def advance_wall(seconds)
      @state = @state.with(wall_time: @state.wall_time + seconds)
      self
    end

    def advance_mono(seconds)
      @state = @state.with(mono_time: @state.mono_time + seconds)
      self
    end

    def advance(seconds)
      advance_wall(seconds)
      advance_mono(seconds)
    end
  end

  def build_clock(wall_time: Time.utc(2026, 4, 15, 0, 0, 0), mono_time: 0.0)
    MutableClock.new(wall_time: wall_time, mono_time: mono_time)
  end

  def build_memory_store
    DAG::Workflow::ExecutionStore::MemoryStore.new
  end

  def temp_path(prefix: "dag_test", suffix: ".txt")
    File.join(TEST_TMPDIR, "#{prefix}_#{$$}_#{SecureRandom.hex(6)}#{suffix}")
  end

  def example_env
    {
      "TMPDIR" => TEST_TMPDIR,
      "HOME" => ENV.fetch("HOME", Dir.pwd)
    }
  end
end
