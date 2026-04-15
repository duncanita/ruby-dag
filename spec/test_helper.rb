# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
    minimum_coverage line: 100, branch: 100
  end
end

require "minitest/autorun"
require "securerandom"
require "tempfile"
require "tmpdir"

require_relative "../lib/dag"

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

      graph.add_node(name)
      registry.register(DAG::Workflow::Step.new(name: name, type: type, **opts))
      depends_on.each { |dep| deferred_edges << [dep, name] }
    end

    deferred_edges.each { |from, to| graph.add_edge(from, to) }

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

  def temp_path(prefix: "dag_test", suffix: ".txt")
    dir = Dir.tmpdir
    File.join(dir, "#{prefix}_#{$$}_#{SecureRandom.hex(6)}#{suffix}")
  end
end
