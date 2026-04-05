# frozen_string_literal: true

module DAG
  module Workflow
    # Executes a workflow: takes a Graph (execution order) + Registry (step definitions).
    # Nodes in the same layer run in parallel via Ractors (Ruby 4+).
    #
    #   result = DAG::Workflow::Runner.new(graph, registry).call
    #   result.value[:parse].value  #=> "parsed output"

    class Runner
      def initialize(graph, registry, parallel: true, on_step_start: nil, on_step_finish: nil)
        @graph = graph
        @registry = registry
        @parallel = parallel
        @callbacks = RunCallbacks.new(on_step_start: on_step_start, on_step_finish: on_step_finish)
      end

      def call
        @graph.topological_layers
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
          results[name] = execute_step(name, previous_outputs)
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
        step = @registry[name]
        input = gather_input(name, previous_outputs)
        step_data = serialize_step(step)

        @callbacks.start(name, step)

        Ractor.new(name, step_data, input, results_port) do |n, sd, inp, out|
          executor = DAG::Workflow::Steps.build(sd[:type])
          reconstructed = DAG::Workflow::Step.new(name: sd[:name], type: sd[:type], **sd[:config])
          result = executor.call(reconstructed, inp)

          out.send([n, result.to_h])
        end
      end

      def serialize_step(step)
        {
          name: step.name,
          type: step.type,
          config: deep_freeze(step.config)
        }
      end

      def deserialize_result(hash)
        if hash[:status] == :success
          Success.new(value: hash[:value])
        else
          Failure.new(error: hash[:error])
        end
      end

      def execute_step(name, previous_outputs)
        step = @registry[name]
        input = gather_input(name, previous_outputs)

        @callbacks.start(name, step)

        Steps.build(step.type)
          .call(step, input)
          .tap { |result| @callbacks.finish(name, result) }
      end

      def gather_input(name, outputs)
        @graph.predecessors(name)
          .to_a
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
        return obj if obj.frozen?

        case obj
        when Hash then obj.transform_keys(&:to_sym).transform_values { |v| deep_freeze(v) }.freeze
        when Array then obj.map { |v| deep_freeze(v) }.freeze
        when String then obj.dup.freeze
        else obj
        end
      end
    end
  end
end
