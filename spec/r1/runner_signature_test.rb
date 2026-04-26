# frozen_string_literal: true

require_relative "../test_helper"

class RunnerSignatureTest < Minitest::Test
  REQUIRED_KEYWORDS = %i[storage event_bus registry clock id_generator fingerprint serializer].freeze

  def test_missing_any_keyword_raises_argument_error
    full = base_keywords
    REQUIRED_KEYWORDS.each do |key|
      args = full.reject { |k, _| k == key }
      assert_raises(ArgumentError) { DAG::Runner.new(**args) }
    end
  end

  def test_nil_keyword_raises_argument_error
    full = base_keywords
    REQUIRED_KEYWORDS.each do |key|
      args = full.merge(key => nil)
      err = assert_raises(ArgumentError) { DAG::Runner.new(**args) }
      assert_match(/#{key}/, err.message)
    end
  end

  def test_runner_is_frozen_after_initialize
    runner = DAG::Runner.new(**base_keywords)
    assert runner.frozen?
  end

  private

  def base_keywords
    {
      storage: DAG::Adapters::Memory::Storage.new,
      event_bus: DAG::Adapters::Null::EventBus.new,
      registry: default_test_registry,
      clock: DAG::Adapters::Stdlib::Clock.new,
      id_generator: DAG::Adapters::Stdlib::IdGenerator.new,
      fingerprint: DAG::Adapters::Stdlib::Fingerprint.new,
      serializer: DAG::Adapters::Stdlib::Serializer.new
    }
  end
end
