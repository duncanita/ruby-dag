# frozen_string_literal: true

module StepHelpers
  def registry_with_logging_step(call_log)
    registry = DAG::StepTypeRegistry.new
    log_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        call_log << input.node_id
        DAG::Success[value: input.node_id, context_patch: {input.node_id => :seen}]
      end
    end
    registry.register(name: :logging, klass: log_class, fingerprint_payload: {v: 1})
    registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end

  def registry_with_failing_step(failures_before_success:, code: :boom)
    counter = {value: 0}
    registry = DAG::StepTypeRegistry.new
    klass = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        counter[:value] += 1
        if counter[:value] <= failures_before_success
          DAG::Failure[error: {code: code, message: "attempt #{counter[:value]}"}, retriable: true]
        else
          DAG::Success[value: counter[:value], context_patch: {}]
        end
      end
    end
    registry.register(name: :flaky, klass: klass, fingerprint_payload: {v: 1, before: failures_before_success})
    registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    registry.freeze!
    [registry, counter]
  end

  def node_state(storage, workflow_id, node_id)
    workflow = storage.load_workflow(id: workflow_id)
    storage.load_node_states(workflow_id: workflow_id, revision: workflow[:current_revision])[node_id]
  end
end
