# frozen_string_literal: true

require "etc"

module DAG
  module Workflow
    TraceEntry = Data.define(:name, :layer, :started_at, :finished_at, :duration_ms, :status, :input_keys)

    class Runner
      DEFAULT_MAX_PARALLELISM = [Etc.nprocessors, 8].min

      # Accepts either a Definition (the common case after Loader) or a
      # `(graph, registry)` pair for code that built the pieces by hand.
      #
      # parallel may be:
      #   true / :threads     -> Thread pool (default)
      #   false / :sequential -> single-threaded loop
      #   :processes          -> fork/pipe with hard concurrency cap
      #
      # timeout: optional wall-clock cap (seconds, Numeric) on the entire run.
      # Checked between layers — a layer that is already running will not be
      # interrupted, but no further layers start once the deadline passes.
      # Per-step timeouts on `:exec` / `:ruby_script` still apply inside a
      # layer; if you put a long pure-Ruby `:ruby` callable in a single layer,
      # nothing in this library can interrupt it. Use `:processes` if you need
      # hard isolation.
      def initialize(graph_or_definition, registry = nil, parallel: true,
        max_parallelism: DEFAULT_MAX_PARALLELISM,
        timeout: nil,
        on_step_start: nil, on_step_finish: nil)
        graph, registry = unpack_definition(graph_or_definition, registry)
        @graph = graph
        @registry = registry
        @timeout = timeout
        @callbacks = RunCallbacks.new(on_step_start: on_step_start, on_step_finish: on_step_finish)
        @strategy = build_strategy(parallel, max_parallelism)
        validate_coverage!(graph, registry)
      end

      def call
        deadline = @timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout : nil
        execute_layers(@graph.topological_layers, deadline)
      end

      private

      def build_strategy(parallel, max_parallelism)
        case parallel
        when false, :sequential
          Parallel::Sequential.new
        when true, :threads
          Parallel::Threads.new(max_parallelism: max_parallelism)
        when :processes
          Parallel::Processes.new(max_parallelism: max_parallelism)
        else
          raise ArgumentError, "Unknown parallel mode: #{parallel.inspect}. " \
                               "Use true, false, :sequential, :threads, or :processes."
        end
      end

      def unpack_definition(graph, registry)
        case graph
        when Definition
          raise ArgumentError, "Runner.new(definition) takes no registry argument" if registry
          graph.deconstruct
        else
          raise ArgumentError, "Runner.new(graph, registry) requires a registry" if registry.nil?
          [graph, registry]
        end
      end

      def executor_class(type) = Steps.class_for(type)

      def execute_layers(layers, deadline)
        outputs = {}
        trace = []
        failed_name = nil
        failed_result = nil

        layers.each_with_index do |layer, layer_index|
          break if failed_name

          if deadline_passed?(deadline)
            failed_name = :workflow_timeout
            failed_result = Failure.new(error: {
              code: :workflow_timeout,
              message: "workflow exceeded #{@timeout}s wall-clock deadline",
              timeout_seconds: @timeout
            })
            break
          end

          execute_layer(layer, layer_index, outputs, trace).each do |name, result|
            outputs[name] = result
            if result.failure? && failed_name.nil?
              failed_name = name
              failed_result = result
            end
          end
        end

        if failed_name
          Failure.new(error: wrap_payload(outputs, trace,
            {failed_node: failed_name, step_error: failed_result.error}))
        else
          Success.new(value: wrap_payload(outputs, trace, nil))
        end
      end

      def deadline_passed?(deadline)
        deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      end

      # Single shape for both Success and Failure: callers always see
      # `:outputs`, `:trace`, and `:error` keys regardless of branch.
      def wrap_payload(outputs, trace, step_error)
        {outputs: outputs, trace: trace, error: step_error}
      end

      # Callback ordering contract: every runnable :start in a layer fires
      # before any :finish in that layer, so a consumer logging "layer
      # begins" on the first :start sees a coherent sequence. Skipped
      # steps have no :start — they finish immediately after the runnable
      # :start batch. Strategy is picked before any callback fires, so a
      # consumer querying strategy identity from inside :start sees the
      # one actually running.
      def execute_layer(layer, layer_index, previous_outputs, trace)
        runnable, skipped, failed = partition_layer(layer, previous_outputs)
        results = {}

        record_run_if_failures(failed, results, layer_index, trace)
        runnable.each { |t| @callbacks.start(t.name, t.step) }
        record_skipped(skipped, results, layer_index, trace)
        run_tasks(runnable, layer_index, trace, results)

        results
      end

      def partition_layer(layer, previous_outputs)
        runnable = []
        skipped = []
        failed = []

        layer.each do |name|
          step = @registry[name]
          input = resolve_input(name, previous_outputs)
          input_keys = input.keys.sort

          begin
            if skip?(step, input)
              skipped << [name, step, input_keys]
            else
              runnable << Parallel::Task.new(
                name: name, step: step, input: input,
                executor_class: executor_class(step.type),
                input_keys: input_keys
              )
            end
          rescue => e
            failed << [name, input_keys, Result.exception_failure(:run_if_error, e,
              message: "run_if for step #{name} raised: #{e.message}")]
          end
        end

        [runnable, skipped, failed]
      end

      # Short-circuits on an empty task list (a layer in which every step
      # was filtered by `run_if`): no point handing an empty array to the
      # strategy, and it keeps the trace ordering tidy.
      def run_tasks(tasks, layer_index, trace, results)
        return if tasks.empty?

        input_keys_by_name = tasks.to_h { |t| [t.name, t.input_keys] }

        @strategy.execute(tasks) do |name, result, started_at, finished_at, duration_ms|
          trace << build_trace_entry(name, layer_index, result,
            started_at: started_at, finished_at: finished_at, duration_ms: duration_ms,
            input_keys: input_keys_by_name.fetch(name))
          @callbacks.finish(name, result)
          results[name] = result
        end
      end

      def skip?(step, input)
        run_if = step.config[:run_if]
        run_if && !run_if.call(input)
      end

      def record_skipped(skipped, results, layer_index, trace)
        skipped.each do |name, step, input_keys|
          results[name] = record_skip(name, step, layer_index, input_keys, trace)
        end
      end

      def record_run_if_failures(failed, results, layer_index, trace)
        failed.each do |name, input_keys, failure_result|
          trace << build_trace_entry(name, layer_index, failure_result,
            started_at: nil, finished_at: nil, duration_ms: 0,
            input_keys: input_keys)
          @callbacks.finish(name, failure_result)
          results[name] = failure_result
        end
      end

      def record_skip(name, step, layer_index, input_keys, trace)
        result = Success.new(value: nil)
        trace << build_trace_entry(name, layer_index, result,
          started_at: nil, finished_at: nil, duration_ms: 0,
          input_keys: input_keys, status: :skipped)
        @callbacks.finish(name, result)
        result
      end

      def build_trace_entry(name, layer_index, result, started_at:, finished_at:, duration_ms:, input_keys:, status: nil)
        TraceEntry.new(
          name: name, layer: layer_index,
          started_at: started_at, finished_at: finished_at,
          duration_ms: duration_ms,
          status: status || (result.success? ? :success : :failure),
          input_keys: input_keys
        )
      end

      # Predecessors always have a Result in `outputs` by the time we
      # resolve a downstream layer — skipped steps still record Success(nil).
      def resolve_input(name, outputs)
        @graph.each_predecessor(name).to_h { |dep| [dep, outputs[dep].value] }
      end

      def validate_coverage!(graph, registry)
        missing = graph.nodes.reject { |node| registry.key?(node) }
        return if missing.empty?

        raise ValidationError, "Missing steps for graph nodes: #{missing.sort.join(", ")}"
      end
    end
  end
end
