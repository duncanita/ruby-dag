# frozen_string_literal: true

require_relative "../test_helper"

class FingerprintJsonSafetyTest < Minitest::Test
  def setup
    @fingerprint = DAG::Adapters::Stdlib::Fingerprint.new
  end

  def test_rejects_canonical_key_collisions
    assert_raises(ArgumentError) { @fingerprint.compute({:a => 1, "a" => 2}) }
  end

  def test_rejects_non_finite_floats
    assert_raises(ArgumentError) { @fingerprint.compute({x: Float::NAN}) }
    assert_raises(ArgumentError) { @fingerprint.compute({x: Float::INFINITY}) }
    assert_raises(ArgumentError) { @fingerprint.compute({x: -Float::INFINITY}) }
  end

  def test_rejects_time_values
    assert_raises(ArgumentError) { @fingerprint.compute({created_at: Time.now}) }
  end
end
