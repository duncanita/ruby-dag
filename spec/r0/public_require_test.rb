# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

class R0PublicRequireTest < Minitest::Test
  def test_public_require_loads_cleanly
    stdout, stderr, status = Open3.capture3(
      Gem.ruby,
      "-Ilib",
      "-e",
      "require 'ruby-dag'; puts DAG::VERSION"
    )

    assert status.success?, stderr
    assert_match(/\A0\.\d+\.0\z/, stdout.strip)
  end
end
