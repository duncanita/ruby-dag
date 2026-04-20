# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class CLIWorkflowTest < Minitest::Test
  include TestHelpers

  def test_bin_dag_runs_deploy_yml_success
    stdout, stderr, status = run_bin_dag("examples/deploy.yml")

    assert status.success?, <<~MSG
      expected deploy.yml to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "✓ Workflow completed"
    assert_includes stdout, "5 nodes"
  end

  def test_bin_dag_exits_nonzero_on_failure
    yaml = build_failure_yaml
    with_tempfile(yaml) do |path|
      stdout, stderr, status = run_bin_dag(path)

      refute status.success?, <<~MSG
        expected failure workflow to exit non-zero
        stdout:
        #{stdout}
        stderr:
        #{stderr}
      MSG

      assert_includes stderr, "✗ Failed at"
      assert_includes stderr, "exit"
    end
  end

  def test_bin_dag_dry_run_shows_plan
    stdout, stderr, status = run_bin_dag("examples/deploy.yml", extra_args: ["--dry-run"])

    assert status.success?, <<~MSG
      expected dry-run to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "Workflow:"
    assert_includes stdout, "Nodes:"
    assert_includes stdout, "Execution order:"
    assert_includes stdout, "Layer"
  end

  def test_bin_dag_no_parallel_sequential
    stdout, stderr, status = run_bin_dag("examples/deploy.yml", extra_args: ["--no-parallel"])

    assert status.success?, <<~MSG
      expected --no-parallel run to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "✓ Workflow completed"
  end

  def test_bin_dag_load_error_exits_code_2
    stdout, stderr, status = run_bin_dag("nonexistent.yml")

    refute status.success?, <<~MSG
      expected nonexistent file to fail
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_equal 2, status.exitstatus
    assert_includes stderr, "failed to load"
  end

  def test_bin_dag_help_exits_code_0
    stdout, stderr, status = run_bin_dag("--help")

    assert status.success?, <<~MSG
      expected --help to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "Usage:"
    assert_includes stdout, "Options:"
  end

  private

  def run_bin_dag(file_or_arg, extra_args: [])
    args = (file_or_arg == "--help") ? ["--help"] : [file_or_arg, *extra_args]
    Open3.capture3(example_env,
      Gem.ruby, "-Ilib", "bin/dag", *args,
      chdir: File.expand_path("..", __dir__))
  end

  def build_failure_yaml
    <<~YAML
      name: cli-fail-test
      description: "Failure test for CLI"
      nodes:
        fail_step:
          type: exec
          command: "exit 1"
    YAML
  end
end
