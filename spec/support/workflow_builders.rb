# frozen_string_literal: true

module WorkflowBuilders
  def simple_definition
    DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_edge(:a, :b)
  end

  def three_node_chain(a, b, c)
    DAG::Workflow::Definition.new
      .add_node(a, type: :passthrough)
      .add_node(b, type: :passthrough)
      .add_node(c, type: :passthrough)
      .add_edge(a, b)
      .add_edge(b, c)
  end

  def fan_out_fan_in(root, branches, sink)
    definition = DAG::Workflow::Definition.new.add_node(root, type: :passthrough)
    branches.each { |id| definition = definition.add_node(id, type: :passthrough).add_edge(root, id) }
    definition = definition.add_node(sink, type: :passthrough)
    branches.each { |id| definition = definition.add_edge(id, sink) }
    definition
  end

  def create_workflow(storage, definition, initial_context: {}, runtime_profile: DAG::RuntimeProfile.default)
    id = SecureRandom.uuid
    storage.create_workflow(
      id: id,
      initial_definition: definition,
      initial_context: initial_context,
      runtime_profile: runtime_profile
    )
    id
  end

  def create_committed_workflow(storage, definition, terminal_state: :paused)
    workflow_id = create_workflow(storage, definition)
    definition.topological_order.each { |node_id| commit_node(storage, workflow_id, definition.revision, node_id) }
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: terminal_state)
    workflow_id
  end

  def commit_node(storage, workflow_id, revision, node_id)
    attempt_id = storage.begin_attempt(
      workflow_id: workflow_id,
      revision: revision,
      node_id: node_id,
      expected_node_state: :pending
    )
    storage.commit_attempt(
      attempt_id: attempt_id,
      result: DAG::Success[value: node_id, context_patch: {node_id => true}],
      node_state: :committed,
      event: DAG::Event[
        type: :node_committed,
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: 0,
        payload: {}
      ]
    )
  end
end
