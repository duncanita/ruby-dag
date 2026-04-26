# frozen_string_literal: true

require_relative "../test_helper"

class FingerprintDeterminismTest < Minitest::Test
  def test_hash_key_order_does_not_change_digest
    fingerprint = DAG::Adapters::Stdlib::Fingerprint.new

    left = fingerprint.compute({b: [2, {z: true}], a: 1})
    right = fingerprint.compute({a: 1, b: [2, {z: true}]})

    assert_equal left, right
  end

  def test_symbol_keys_and_string_keys_share_canonical_form
    fingerprint = DAG::Adapters::Stdlib::Fingerprint.new

    assert_equal fingerprint.compute({a: 1}), fingerprint.compute({"a" => 1})
  end
end
