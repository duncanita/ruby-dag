# frozen_string_literal: true

module DAG
  module Workflow
    # Executes a workflow: takes a Graph (execution order) + Registry (step definitions).
    # Nodes in the same layer run in parallel via Ractors (Ruby 4+).
    #
    #   result = DAG::Workflow::Runner.new(graph, registry).call
    #   result.value[:outputs][:parse].value  #=> "parsed output"
    #   result.value[:trace]                  #=> [TraceEntry, ...]
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

    TraceEntry = Data.define(:name, :layer, :started_at, :finished_at, :duration_ms, :status, :input_keys)

    class Runner
      def initialize(graph, registry, parallel: true, on_step_start: nil, on_step_finish: nil)
        @graph = graph
        @registry = registry
        @parallel = parallel
        @callbacks = RunCallbacks.new(on_step_start: on_step_start, on_step_finish: on_step_finish)
        validate_coverage!(graph, registry)
      end

      def call
        @graph.topological_layers
          .then { |layers| execute_layers(layers) }
      end

      private

      def execute_layers(layers)
        outputs = {}
        trace = []

        layers.each_with_index do |layer, layer_index|
          execute_layer(layer, layer_index, outputs, trace).each do |name, result|
            outputs[name] = result
            return build_failure(name, result, outputs, trace) if result.failure?
          end
        end

        Success.new(value: {outputs: outputs, trace: trace})
      end

      def execute_layer(layer, layer_index, previous_outputs, trace)
        if @parallel && layer.size > 1
          execute_parallel(layer, layer_index, previous_outputs, trace)
        else
          execute_sequential(layer, layer_index, previous_outputs, trace)
        end
      end

      def execute_sequential(layer, layer_index, previous_outputs, trace)
        layer.each_with_object({}) do |name, results|
          results[name] = execute_step(name, layer_index, previous_outputs, trace)
        end
      end

      def execute_parallel(layer, layer_index, previous_outputs, trace)
        results_port = Ractor::Port.new

        ractors = layer.map { |name| spawn_ractor(name, previous_outputs, results_port) }

        results = {}
        layer.size.times do
          name, result_hash, duration_ms = results_port.receive
          result = deserialize_result(result_hash)
          trace << build_trace_entry(name, layer_index, result, duration_ms: duration_ms)
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
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = klass.new.call(s, inp)
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
          out.send([n, result.to_h, elapsed])
        end
      end

      def deserialize_result(hash)
        if hash[:status] == :success
          Success.new(value: hash[:value])
        else
          Failure.new(error: hash[:error])
        end
      end

      def execute_step(name, layer_index, previous_outputs, trace)
        step = @registry[name]
        deps = @graph.predecessors(name).to_a
        input = resolve_dependencies(deps, previous_outputs)

        @callbacks.start(name, step)

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = Steps.build(step.type).call(step, input)
        finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        duration_ms = ((finished_at - started_at) * 1000).round(2)

        trace << build_trace_entry(name, layer_index, result,
          started_at: started_at, finished_at: finished_at, duration_ms: duration_ms,
          input_keys: deps.sort)

        @callbacks.finish(name, result)
        result
      end

      def build_trace_entry(name, layer_index, result, duration_ms:, started_at: nil, finished_at: nil, input_keys: nil)
        input_keys ||= @graph.predecessors(name).to_a.sort
        TraceEntry.new(
          name: name, layer: layer_index,
          started_at: started_at, finished_at: finished_at,
          duration_ms: duration_ms,
          status: result.success? ? :success : :failure,
          input_keys: input_keys
        )
      end

      def gather_input(name, outputs)
        @graph.predecessors(name)
          .to_a
          .then { |deps| resolve_dependencies(deps, outputs) }
      end

      def resolve_dependencies(deps, outputs)
        deps.to_h { |dep| [dep, outputs[dep]&.value] }
      end

      def validate_coverage!(graph, registry)
        missing = graph.nodes.reject { |node| registry.key?(node) }
        return if missing.empty?

        raise ValidationError, "Missing steps for graph nodes: #{missing.sort.join(", ")}"
      end

      def build_failure(name, result, outputs, trace)
        Failure.new(error: {failed_node: name, error: result.error, outputs: outputs, trace: trace})
      end
    end
  end
end
