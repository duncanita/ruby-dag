# frozen_string_literal: true

require "open3"
require_relative "../test_helper"

class R3RuntimeSnapshotExampleTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_runtime_snapshot_example_runs_as_a_process
    stdout, stderr, status = Open3.capture3(
      Gem.ruby,
      "-Ilib",
      "examples/runtime_snapshot.rb",
      chdir: ROOT
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_includes stdout, "revision=1"
    assert_includes stdout, "node_id=inspect"
    assert_includes stdout, "attempt_number=1"
    assert_includes stdout, "predecessor_source=hello"
    assert_includes stdout, "context_source=hello"
    assert_includes stdout, "effect_count=0"
  end
end
