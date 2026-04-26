# frozen_string_literal: true

require_relative "../test_helper"

class R0PortsTest < Minitest::Test
  def test_storage_port_methods_raise_port_not_implemented
    adapter = Class.new { include DAG::Ports::Storage }.new

    assert_raises(DAG::PortNotImplementedError) do
      adapter.load_workflow(id: "wf")
    end
  end

  def test_event_bus_port_methods_raise_port_not_implemented
    adapter = Class.new { include DAG::Ports::EventBus }.new

    assert_raises(DAG::PortNotImplementedError) do
      adapter.publish(DAG::Event[type: :workflow_started, workflow_id: "wf", revision: 1, at_ms: 1])
    end
  end
end
