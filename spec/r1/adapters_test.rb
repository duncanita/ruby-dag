# frozen_string_literal: true

require_relative "../test_helper"

class AdaptersTest < Minitest::Test
  def test_stdlib_clock_methods
    clock = DAG::Adapters::Stdlib::Clock.new
    assert clock.frozen?
    assert_kind_of Time, clock.now
    assert_kind_of Integer, clock.now_ms
    assert_kind_of Integer, clock.monotonic_ms
    assert_operator clock.monotonic_ms, :<=, clock.monotonic_ms + 1
  end

  def test_stdlib_id_generator_returns_uuid
    ids = Array.new(20) { DAG::Adapters::Stdlib::IdGenerator.new.call }
    assert_equal 20, ids.uniq.size
    ids.each { |id| assert_match(/\A[0-9a-f-]{36}\z/, id) }
  end

  def test_stdlib_fingerprint_is_canonical
    fp = DAG::Adapters::Stdlib::Fingerprint.new
    assert_equal fp.compute({a: 1, b: 2}), fp.compute({b: 2, a: 1})
    refute_equal fp.compute({a: 1}), fp.compute({a: 2})
  end

  def test_stdlib_fingerprint_rejects_non_finite_floats
    fp = DAG::Adapters::Stdlib::Fingerprint.new
    assert_raises(ArgumentError) { fp.compute({x: Float::NAN}) }
    assert_raises(ArgumentError) { fp.compute({x: Float::INFINITY}) }
  end

  def test_stdlib_fingerprint_handles_arrays_and_floats_and_booleans
    fp = DAG::Adapters::Stdlib::Fingerprint.new
    assert_match(/\A[0-9a-f]{64}\z/, fp.compute({a: [1, 2.5, true, false, nil]}))
  end

  def test_stdlib_serializer_round_trips
    sr = DAG::Adapters::Stdlib::Serializer.new
    assert_equal({"a" => 1, "b" => [1, 2]}, sr.load(sr.dump({a: 1, b: [1, 2]})))
  end

  def test_null_event_bus_drops
    bus = DAG::Adapters::Null::EventBus.new
    bus.publish(:event)
    unsubscribe = bus.subscribe { |_| flunk "subscribe should be inert" }
    assert_kind_of Proc, unsubscribe
    assert_nil unsubscribe.call
  end

  def test_memory_event_bus_appends_and_subscribes
    bus = DAG::Adapters::Memory::EventBus.new(buffer_size: 2)
    received = []
    bus.subscribe { |e| received << e }

    e1 = build_event(:node_started)
    e2 = build_event(:node_committed)
    e3 = build_event(:workflow_completed)
    bus.publish(e1)
    bus.publish(e2)
    bus.publish(e3)

    assert_equal [:node_started, :node_committed, :workflow_completed], received.map(&:type)
    assert_equal [:node_committed, :workflow_completed], bus.events.map(&:type)
  end

  def test_memory_event_bus_publish_uses_subscriber_snapshot
    bus = DAG::Adapters::Memory::EventBus.new
    received = []
    bus.subscribe do |event|
      received << [:first, event.type]
      bus.subscribe { |nested| received << [:second, nested.type] }
    end

    bus.publish(build_event(:node_started))
    bus.publish(build_event(:node_committed))

    assert_equal [
      [:first, :node_started],
      [:first, :node_committed],
      [:second, :node_committed]
    ], received
  end

  def test_memory_event_bus_events_are_deep_frozen
    bus = DAG::Adapters::Memory::EventBus.new
    bus.publish(build_event(:node_started, payload: {data: [1, 2]}))
    assert bus.events.frozen?
    assert bus.events.first.frozen?
  end

  private

  def build_event(type, payload: {})
    DAG::Event[
      type: type,
      workflow_id: "wf",
      revision: 1,
      at_ms: 1_700_000_000_000,
      payload: payload
    ]
  end
end
