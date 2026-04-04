# frozen_string_literal: true

module DAG
  # Executes a validated Graph layer by layer.
  # Nodes in the same layer run in parallel via threads.
  #
  #   runner = DAG::Runner.new(graph)
  #   result = runner.call
  #   result.value[:parse].value  #=> "parsed output"

  RunCallbacks = Data.define(:on_node_start, :on_node_finish) do
    def initialize(on_node_start: nil, on_node_finish: nil) = super
    def start(name, node) = on_node_start&.call(name, node)
    def finish(name, result) = on_node_finish&.call(name, result)
  end

  class Runner
    def initialize(graph, parallel: true, **callback_opts)
      @graph = graph
      @parallel = parallel
      @callbacks = RunCallbacks.new(**callback_opts)
    end

    def call
      @graph.execution_order
        .then { |layers| execute_layers(layers) }
    end

    private

    def execute_layers(layers)
      outputs = {}

      layers.each do |layer|
        execute_layer(layer, outputs).each do |name, result|
          outputs[name] = result
          return build_failure(name, result, outputs) if result.failure?
        end
      end

      Success.new(value: outputs)
    end

    def execute_layer(layer, previous_outputs)
      if @parallel && layer.size > 1
        execute_parallel(layer, previous_outputs)
      else
        execute_sequential(layer, previous_outputs)
      end
    end

    def execute_sequential(layer, previous_outputs)
      layer.each_with_object({}) do |name, results|
        results[name] = execute_node(name, previous_outputs)
      end
    end

    def execute_parallel(layer, previous_outputs)
      layer
        .map { |name| spawn_thread(name, previous_outputs) }
        .each_with_object({}) { |thread, results| name, result = thread.value; results[name] = result }
    end

    def spawn_thread(name, previous_outputs)
      Thread.new do
        [name, execute_node(name, previous_outputs)]
      end
    end

    def execute_node(name, previous_outputs)
      node = @graph.node(name)
      input = gather_input(node, previous_outputs)

      @callbacks.start(name, node)

      Steps.build(node.type)
        .call(node, input)
        .tap { |result| @callbacks.finish(name, result) }
    end

    def gather_input(node, outputs)
      node.depends_on
        .then { |deps| resolve_dependencies(deps, outputs) }
    end

    def resolve_dependencies(deps, outputs)
      case deps.size
      when 0 then nil
      when 1 then outputs[deps.first]&.value
      else deps.to_h { |dep| [dep, outputs[dep]&.value] }
      end
    end

    def build_failure(name, result, outputs)
      Failure.new(error: { failed_node: name, error: result.error, outputs: outputs })
    end
  end
end
