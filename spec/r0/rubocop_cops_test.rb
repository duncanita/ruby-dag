# frozen_string_literal: true

require_relative "../test_helper"
require "rubocop"
require_relative "../../rubocop/cop/dag/no_external_requires"
require_relative "../../rubocop/cop/dag/no_in_place_mutation"
require_relative "../../rubocop/cop/dag/no_mutable_accessors"
require_relative "../../rubocop/cop/dag/no_thread_or_ractor"

class R0RuboCopCopsTest < Minitest::Test
  def test_no_thread_or_ractor_flags_thread_primitives
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoThreadOrRactor,
      "Thread.new { :work }\n",
      path: runtime_path("thread_example.rb")
    )

    refute_empty offenses
  end

  def test_no_thread_or_ractor_flags_runtime_process_spawn
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoThreadOrRactor,
      "Process.spawn('echo', 'ok')\n",
      path: runtime_path("spawn_example.rb")
    )

    refute_empty offenses
  end

  def test_no_thread_or_ractor_allows_process_clock_gettime
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoThreadOrRactor,
      "Process.clock_gettime(Process::CLOCK_MONOTONIC)\n",
      path: runtime_path("clock_example.rb")
    )

    assert_empty offenses
  end

  def test_no_thread_or_ractor_allows_process_spawn_outside_runtime
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoThreadOrRactor,
      "Process.spawn('echo', 'ok')\n",
      path: spec_path("spawn_example_test.rb")
    )

    assert_empty offenses
  end

  def test_no_thread_or_ractor_flags_bare_system_in_runtime
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoThreadOrRactor,
      "system('echo ok')\n",
      path: runtime_path("system_example.rb")
    )

    refute_empty offenses
  end

  def test_no_thread_or_ractor_flags_backticks_in_runtime
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoThreadOrRactor,
      "`echo ok`\n",
      path: runtime_path("backtick_example.rb")
    )

    refute_empty offenses
  end

  def test_no_mutable_accessors_flags_runtime_attr_accessor
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoMutableAccessors,
      "class Demo\n  attr_accessor :state\nend\n",
      path: runtime_path("mutable_accessor.rb")
    )

    refute_empty offenses
  end

  def test_no_in_place_mutation_flags_pure_kernel_mutation
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoInPlaceMutation,
      "values = []\nvalues << :item\n",
      path: runtime_path("types.rb")
    )

    refute_empty offenses
  end

  def test_no_in_place_mutation_flags_effect_value_mutation
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoInPlaceMutation,
      "values = []\nvalues << :item\n",
      path: runtime_path("effects/intent.rb")
    )

    refute_empty offenses
  end

  def test_no_external_requires_flags_non_stdlib_runtime_requires
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoExternalRequires,
      "require 'active_support'\n",
      path: runtime_path("external_require.rb")
    )

    refute_empty offenses
  end

  def test_no_external_requires_allows_stdlib_runtime_requires
    offenses = inspect_source(
      RuboCop::Cop::DAG::NoExternalRequires,
      "require 'json'\n",
      path: runtime_path("json_require.rb")
    )

    assert_empty offenses
  end

  private

  def inspect_source(cop_class, source, path:)
    config = RuboCop::Config.new(
      "AllCops" => {"TargetRubyVersion" => 3.4},
      cop_class.cop_name => {"Enabled" => true}
    )
    cop = cop_class.new(config)
    processed_source = RuboCop::ProcessedSource.new(source, 3.4, path)
    commissioner = RuboCop::Cop::Commissioner.new([cop], [], raise_error: true)

    commissioner.investigate(processed_source).offenses
  end

  def runtime_path(name)
    File.expand_path("../../lib/dag/#{name}", __dir__)
  end

  def spec_path(name)
    File.expand_path("../#{name}", __dir__)
  end
end
