# frozen_string_literal: true

Warning[:experimental] = false

module DAG
  # Executes a validated Graph layer by layer.
  # Nodes in the same layer run in parallel via Ractors (Ruby 4+).
  #
  #   result = DAG::Runner.new(graph).call
  #   result.value[:parse].value  #=> "parsed output"

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
      results_port = Ractor::Port.new

      ractors = layer.map { |name| spawn_ractor(name, previous_outputs, results_port) }

      results = {}
      layer.size.times do
        name, result_hash = results_port.receive
        result = deserialize_result(result_hash)
        @callbacks.finish(name, result)
        results[name] = result
      end

      ractors.each(&:join)
      results
    end

    def spawn_ractor(name, previous_outputs, results_port)
      graph_node = @graph.node(name)
      input = gather_input(graph_node, previous_outputs)
      node_data = serialize_node(graph_node)

      @callbacks.start(name, graph_node)

      Ractor.new(name, node_data, input, results_port) do |n, nd, inp, out|
        step = DAG::Steps.build(nd[:type])
        reconstructed = DAG::Node.new(name: nd[:name], type: nd[:type], **nd[:config])
        result = step.call(reconstructed, inp)

        out.send([n, result.to_h])
      end
    end

    def serialize_node(node)
      {
        name: node.name,
        type: node.type,
        config: deep_freeze(node.config)
      }
    end

    def deserialize_result(hash)
      if hash[:status] == :success
        Success.new(value: hash[:value])
      else
        Failure.new(error: hash[:error])
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
      Failure.new(error: {failed_node: name, error: result.error, outputs: outputs})
    end

    def deep_freeze(obj)
      case obj
      when Hash then obj.transform_keys(&:to_sym).transform_values { |v| deep_freeze(v) }.freeze
      when Array then obj.map { |v| deep_freeze(v) }.freeze
      when String then obj.frozen? ? obj : obj.dup.freeze
      else obj
      end
    end
  end
end
