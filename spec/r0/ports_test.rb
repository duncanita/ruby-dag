# frozen_string_literal: true

require_relative "../test_helper"

class R0PortsTest < Minitest::Test
  STORAGE_OWN_METHODS = {
    create_workflow: {id: "x", initial_definition: nil, initial_context: {}, runtime_profile: nil},
    load_workflow: {id: "x"},
    transition_workflow_state: {id: "x", from: :pending, to: :running},
    append_revision: {id: "x", parent_revision: 1, definition: nil, invalidated_node_ids: [], event: nil},
    append_revision_if_workflow_state: {
      id: "x",
      allowed_states: [:pending],
      parent_revision: 1,
      definition: nil,
      invalidated_node_ids: [],
      event: nil
    },
    load_revision: {id: "x", revision: 1},
    load_current_definition: {id: "x"},
    load_node_states: {workflow_id: "x", revision: 1},
    transition_node_state: {workflow_id: "x", revision: 1, node_id: :a, from: :pending, to: :running},
    begin_attempt: {workflow_id: "x", revision: 1, node_id: :a, expected_node_state: :pending, attempt_number: 1},
    commit_attempt: {attempt_id: "x", result: nil, node_state: :committed, event: nil},
    abort_running_attempts: {workflow_id: "x"},
    list_attempts: {workflow_id: "x"},
    list_committed_results_for_predecessors: {workflow_id: "x", revision: 1, predecessors: [:a]},
    count_attempts: {workflow_id: "x", revision: 1, node_id: :a},
    append_event: {workflow_id: "x", event: nil},
    read_events: {workflow_id: "x"},
    prepare_workflow_retry: {id: "x"}
  }.freeze

  EFFECT_LEDGER_METHODS = {
    list_effects_for_node: {workflow_id: "x", revision: 1, node_id: :a},
    list_effects_for_attempt: {attempt_id: "x"},
    claim_ready_effects: {limit: 1, owner_id: "worker", lease_ms: 1, now_ms: 1},
    mark_effect_succeeded: {effect_id: "x", owner_id: "worker", result: {}, external_ref: nil, now_ms: 1},
    mark_effect_failed: {effect_id: "x", owner_id: "worker", error: {}, retriable: true, not_before_ms: nil, now_ms: 1},
    renew_effect_lease: {effect_id: "x", owner_id: "worker", until_ms: 2, now_ms: 1},
    complete_effect_succeeded: {effect_id: "x", owner_id: "worker", result: {}, external_ref: nil, now_ms: 1},
    complete_effect_failed: {effect_id: "x", owner_id: "worker", error: {}, retriable: false, not_before_ms: nil, now_ms: 1},
    release_nodes_satisfied_by_effect: {effect_id: "x", now_ms: 1}
  }.freeze

  STORAGE_METHODS = STORAGE_OWN_METHODS.merge(EFFECT_LEDGER_METHODS).freeze

  ROOT = File.expand_path("../..", __dir__)

  def test_storage_port_method_list_matches_documented_contract
    assert_equal STORAGE_OWN_METHODS.keys.sort, DAG::Ports::Storage.public_instance_methods(false).sort
    assert_equal (EFFECT_LEDGER_METHODS.keys + [:thread_safe_for_dispatch?]).sort,
      DAG::Ports::EffectLedger.public_instance_methods(false).sort
    assert_includes DAG::Ports::Storage.ancestors, DAG::Ports::EffectLedger
  end

  def test_storage_port_public_methods_document_return_shapes
    storage_source = File.read(File.join(ROOT, "lib/dag/ports/storage.rb"))
    ledger_source = File.read(File.join(ROOT, "lib/dag/ports/effect_ledger.rb"))

    {STORAGE_OWN_METHODS => storage_source, EFFECT_LEDGER_METHODS => ledger_source}.each do |methods, source|
      methods.each_key do |method_name|
        method_documentation = source.match(/((?:\s*#.*\n)+)\s*def #{method_name}\(/)
        refute_nil method_documentation, "#{method_name} should have a documentation block"
        assert_includes method_documentation[1], "@return", "#{method_name} should document its return shape"
      end
    end
  end

  FakeTerminalRecord = Struct.new(:id, :terminal) do
    def terminal? = terminal
  end

  def test_effect_ledger_complete_defaults_compose_mark_and_release
    adapter = Class.new {
      include DAG::Ports::EffectLedger

      attr_reader :calls

      def initialize(terminal:)
        @terminal = terminal
        @calls = []
      end

      def mark_effect_succeeded(**kwargs)
        @calls << :mark_succeeded
        R0PortsTest::FakeTerminalRecord.new(kwargs.fetch(:effect_id), true)
      end

      def mark_effect_failed(**kwargs)
        @calls << :mark_failed
        R0PortsTest::FakeTerminalRecord.new(kwargs.fetch(:effect_id), @terminal)
      end

      def release_nodes_satisfied_by_effect(effect_id:, now_ms:)
        @calls << :release
        [{node_id: :a, released_at_ms: now_ms}]
      end
    }

    succeeded = adapter.new(terminal: true)
    completion = succeeded.complete_effect_succeeded(
      effect_id: "e1", owner_id: "w", result: {}, external_ref: nil, now_ms: 5
    )
    assert_equal %i[mark_succeeded release], succeeded.calls
    assert_equal "e1", completion.fetch(:record).id
    assert_equal [{node_id: :a, released_at_ms: 5}], completion.fetch(:released)

    terminal_failure = adapter.new(terminal: true)
    completion = terminal_failure.complete_effect_failed(
      effect_id: "e2", owner_id: "w", error: {}, retriable: false, not_before_ms: nil, now_ms: 6
    )
    assert_equal %i[mark_failed release], terminal_failure.calls
    assert_equal [{node_id: :a, released_at_ms: 6}], completion.fetch(:released)

    retriable_failure = adapter.new(terminal: false)
    completion = retriable_failure.complete_effect_failed(
      effect_id: "e3", owner_id: "w", error: {}, retriable: true, not_before_ms: nil, now_ms: 7
    )
    assert_equal %i[mark_failed], retriable_failure.calls
    assert_equal [], completion.fetch(:released)
  end

  def test_effect_ledger_thread_safe_for_dispatch_defaults_to_false
    adapter = Class.new { include DAG::Ports::EffectLedger }.new
    refute adapter.thread_safe_for_dispatch?
    refute DAG::Adapters::Memory::Storage.new.thread_safe_for_dispatch?
  end

  def test_storage_default_committed_results_uses_attempts_and_raises_on_missing_projection
    adapter_class = Class.new {
      include DAG::Ports::Storage

      def initialize(states:, attempts_by_node:)
        @states = states
        @attempts_by_node = attempts_by_node
      end

      def load_node_states(workflow_id:, revision:)
        @states
      end

      def list_attempts(workflow_id:, revision: nil, node_id: nil)
        @attempts_by_node.fetch(node_id, [])
      end
    }

    success = DAG::Success[value: 1, context_patch: {"k" => 1}]
    adapter = adapter_class.new(
      states: {a: :committed, b: :pending},
      attempts_by_node: {a: [
        {state: :committed, attempt_number: 1, attempt_id: "w/1", result: DAG::Success[value: 0]},
        {state: :committed, attempt_number: 2, attempt_id: "w/2", result: success},
        {state: :failed, attempt_number: 3, attempt_id: "w/3", result: nil}
      ]}
    )

    results = adapter.list_committed_results_for_predecessors(workflow_id: "w", revision: 1, predecessors: %i[a b])
    assert_equal({a: success}, results)

    projected = adapter_class.new(states: {a: :committed}, attempts_by_node: {})
    error = assert_raises(DAG::StaleStateError) do
      projected.list_committed_results_for_predecessors(workflow_id: "w", revision: 1, predecessors: [:a])
    end
    assert_match(/no committed attempt/, error.message)
  end

  def test_runner_does_not_parse_storage_error_messages
    runner = File.read(File.join(ROOT, "lib/dag/runner.rb"))
    storage_error_rescue = /rescue\s+(?:DAG::)?(?:StaleStateError|StaleRevisionError|ConcurrentMutationError|WorkflowRetryExhaustedError)[^\n]*=>\s*(\w+)(?:.|\n){0,200}\1\.message/

    refute_match storage_error_rescue, runner
  end

  def test_storage_port_every_method_raises_port_not_implemented
    adapter = Class.new { include DAG::Ports::Storage }.new
    STORAGE_METHODS.each do |method, args|
      assert_raises(DAG::PortNotImplementedError, "#{method} should raise") { adapter.public_send(method, **args) }
    end
  end

  def test_event_bus_port_methods_raise_port_not_implemented
    adapter = Class.new { include DAG::Ports::EventBus }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.publish(:event) }
    assert_raises(DAG::PortNotImplementedError) { adapter.subscribe { |_| } }
  end

  def test_fingerprint_port_raises_port_not_implemented
    adapter = Class.new { include DAG::Ports::Fingerprint }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.compute({}) }
  end

  def test_clock_port_methods_raise_port_not_implemented
    adapter = Class.new { include DAG::Ports::Clock }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.now }
    assert_raises(DAG::PortNotImplementedError) { adapter.now_ms }
    assert_raises(DAG::PortNotImplementedError) { adapter.monotonic_ms }
  end

  def test_id_generator_port_raises_port_not_implemented
    adapter = Class.new { include DAG::Ports::IdGenerator }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.call }
  end

  def test_serializer_port_raises_port_not_implemented
    adapter = Class.new { include DAG::Ports::Serializer }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.dump({}) }
    assert_raises(DAG::PortNotImplementedError) { adapter.load("{}") }
  end
end
