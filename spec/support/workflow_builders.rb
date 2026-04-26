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
end
