# frozen_string_literal: true

require "open3"
require_relative "../test_helper"

class R3DiagnosticsExampleTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_diagnostics_example_runs_as_a_process
    stdout, stderr, status = Open3.capture3(
      Gem.ruby,
      "-Ilib",
      "examples/diagnostics.rb",
      chdir: ROOT
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_includes stdout, "trace_events=workflow_started,node_started,node_committed,workflow_completed"
    assert_includes stdout, "trace_statuses=started,started,success,completed"
    assert_includes stdout, "node_id=inspect"
    assert_includes stdout, "node_state=committed"
    assert_includes stdout, "attempt_count=1"
    assert_includes stdout, "effects_terminal=nil"
  end
end
