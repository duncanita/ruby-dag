# frozen_string_literal: true

require_relative "../test_helper"

class StepTypeRegistryTest < Minitest::Test
  def test_register_and_lookup
    reg = DAG::StepTypeRegistry.new
    reg.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    entry = reg.lookup(:passthrough)
    assert_equal DAG::BuiltinSteps::Passthrough, entry.klass
    refute entry.cache_instances
  end

  def test_register_accepts_instance_cache_opt_in
    reg = DAG::StepTypeRegistry.new
    reg.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1}, cache_instances: true)

    assert reg.lookup(:passthrough).cache_instances
  end

  def test_register_idempotent_with_same_payload
    reg = DAG::StepTypeRegistry.new
    reg.register(name: :p, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    reg.register(name: :p, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    assert_equal [:p], reg.names
  end

  def test_register_mismatch_raises
    reg = DAG::StepTypeRegistry.new
    reg.register(name: :p, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    error = assert_raises(DAG::FingerprintMismatchError) do
      reg.register(name: :p, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 2})
    end
    assert_includes error.message, ":p"
    assert_includes error.message, "payload={v: 1}"
    assert_includes error.message, "payload={v: 2}"
  end

  def test_lookup_unknown_raises
    reg = DAG::StepTypeRegistry.new.tap(&:freeze!)
    assert_raises(DAG::UnknownStepTypeError) { reg.lookup(:missing) }
  end

  def test_freeze_blocks_register
    reg = DAG::StepTypeRegistry.new
    reg.register(name: :p, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    reg.freeze!
    assert_raises(FrozenError) do
      reg.register(name: :other, klass: DAG::BuiltinSteps::Noop, fingerprint_payload: {v: 1})
    end
  end

  def test_register_rejects_non_step_klass
    reg = DAG::StepTypeRegistry.new
    assert_raises(ArgumentError) do
      reg.register(name: :bad, klass: String, fingerprint_payload: {v: 1})
    end
  end

  def test_register_rejects_non_boolean_cache_instances
    reg = DAG::StepTypeRegistry.new
    assert_raises(ArgumentError) do
      reg.register(name: :bad_cache, klass: DAG::BuiltinSteps::Noop, fingerprint_payload: {v: 1}, cache_instances: :yes)
    end
  end
end
