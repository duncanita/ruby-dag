# frozen_string_literal: true

module DAG
  module Workflow
    # Executes a workflow: takes a Graph (execution order) + Registry (step definitions).
    # Nodes in the same layer run in parallel via Ractors (Ruby 4+).
    #
    #   result = DAG::Workflow::Runner.new(graph, registry).call
    #   result.value[:parse].value  #=> "parsed output"
    #
    # # Execution Contract
    #
    # - Step inputs are always hashes keyed by dependency step name (e.g., { fetch: "data" }).
    #   Zero-dependency steps receive {}.
    # - Step outputs should be JSON-like values (strings, numbers, booleans, arrays, hashes)
    #   when using parallel execution. Arbitrary Ruby objects work only in sequential mode.
    # - Callback ordering is per-step but not globally deterministic across parallel layers.
    # - On first step failure, the workflow halts. Completed outputs and failure details
    #   are returned in the result.

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
        executor_class = Steps.build(step.type).class

        @callbacks.start(name, step)

        Ractor.new(name, step, input, results_port, executor_class) do |n, s, inp, out, klass|
          result = klass.new.call(s, inp)
          out.send([n, result.to_h])
        end
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
        deps.to_h { |dep| [dep, outputs[dep]&.value] }
      end

      def build_failure(name, result, outputs)
        Failure.new(error: {failed_node: name, error: result.error, outputs: outputs})
      end
    end
  end
end
