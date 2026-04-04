# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
    minimum_coverage 90
  end
end

require "minitest/autorun"
require "tempfile"
require_relative "../lib/dag"

module TestHelpers
  def build_test_graph(**node_defs)
    node_defs.each_with_object(DAG::Graph.new) do |(name, opts), graph|
      graph.add_node(name: name, type: :exec, command: "echo #{name}", **opts)
    end
  end

  def with_tempfile(content, suffix: ".txt", prefix: "dag_test")
    file = Tempfile.new([prefix, suffix])
    file.write(content)
    file.close
    yield file.path
  ensure
    file&.unlink
  end
end
