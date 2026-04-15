# frozen_string_literal: true

require_relative "test_helper"

class SchedulePolicyTest < Minitest::Test
  include TestHelpers

  def test_waiting_when_wall_clock_is_before_not_before
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))
    step = build_step(schedule: {not_before: Time.utc(2026, 4, 15, 10, 0, 0)})

    policy = DAG::Workflow::SchedulePolicy.new(step, clock: clock)

    assert policy.waiting?
    refute policy.expired?
    assert_equal Time.utc(2026, 4, 15, 10, 0, 0), policy.not_before
  end

  def test_expired_when_wall_clock_is_after_not_after
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 10, 0, 1))
    step = build_step(schedule: {not_after: Time.utc(2026, 4, 15, 10, 0, 0)})

    policy = DAG::Workflow::SchedulePolicy.new(step, clock: clock)

    refute policy.waiting?
    assert policy.expired?
    assert_equal Time.utc(2026, 4, 15, 10, 0, 0), policy.not_after
  end

  def test_parses_string_schedule_times
    clock = build_clock
    step = build_step(schedule: {
      not_before: "2026-04-15T09:00:00Z",
      not_after: "2026-04-15T10:00:00Z"
    })

    policy = DAG::Workflow::SchedulePolicy.new(step, clock: clock)

    assert_equal Time.utc(2026, 4, 15, 9, 0, 0), policy.not_before
    assert_equal Time.utc(2026, 4, 15, 10, 0, 0), policy.not_after
  end

  def test_builds_deadline_exceeded_failure_payload
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 10, 0, 1))
    step = build_step(schedule: {not_after: "2026-04-15T10:00:00Z"})

    result = DAG::Workflow::SchedulePolicy.new(step, clock: clock).deadline_exceeded_result(:scheduled)

    assert result.failure?
    assert_equal :deadline_exceeded, result.error[:code]
    assert_equal "2026-04-15T10:00:00Z", result.error[:not_after]
    assert_match(/step scheduled missed schedule\.not_after/, result.error[:message])
  end

  private

  def build_step(schedule:)
    DAG::Workflow::Step.new(
      name: :scheduled,
      type: :ruby,
      callable: ->(_input) { DAG::Success.new(value: "ok") },
      schedule: schedule
    )
  end
end
