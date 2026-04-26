# frozen_string_literal: true

require_relative "../test_helper"

class R0ZeroRuntimeDepsTest < Minitest::Test
  def test_gemspec_has_no_runtime_dependencies
    spec = Gem::Specification.load("ruby-dag.gemspec")

    assert_empty spec.runtime_dependencies
  end

  def test_gemspec_requires_ruby_3_4_or_newer
    spec = Gem::Specification.load("ruby-dag.gemspec")

    assert_equal ">= 3.4", spec.required_ruby_version.to_s
  end
end
