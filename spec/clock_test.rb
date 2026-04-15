# frozen_string_literal: true

require_relative "test_helper"

class ClockTest < Minitest::Test
  def test_default_clock_exposes_wall_and_monotonic_time
    clock = DAG::Workflow::Clock.new

    assert_kind_of Time, clock.wall_now
    assert_kind_of Numeric, clock.monotonic_now
  end
end
