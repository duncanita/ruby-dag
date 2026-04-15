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
        clock: Clock.new,
        context: nil,
        middleware: [],
        on_step_start: nil, on_step_finish: nil)
        graph, registry = unpack_definition(graph_or_definition, registry)
        @graph = graph
        @registry = registry
        @timeout = timeout
        @clock = clock
        @context = context
        @middleware = Array(middleware).freeze
        validate_context_parallelism!(parallel, context)
        @callbacks = RunCallbacks.new(on_step_start: on_step_start, on_step_finish: on_step_finish)
        @strategy = build_strategy(parallel, max_parallelism)
        validate_coverage!(graph, registry)
        validate_workflow!(graph, registry)
      end

      def call
        deadline = @timeout ? @clock.monotonic_now + @timeout : nil
        execute_layers(@graph.topological_layers, deadline)
      end

      private

      def validate_context_parallelism!(parallel, context)
        return if context.nil? || parallel != :processes

        raise ValidationError, "Runner context is not supported with parallel: :processes without explicit context serialization hooks"
      end

      def build_strategy(parallel, max_parallelism)
        case parallel
        when false, :sequential
          Parallel::Sequential.new(clock: @clock)
        when true, :threads
          Parallel::Threads.new(max_parallelism: max_parallelism, clock: @clock)
        when :processes
          Parallel::Processes.new(max_parallelism: max_parallelism, clock: @clock)
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
        statuses = {}
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

          execute_layer(layer, layer_index, outputs, statuses, trace, deadline).each do |name, result|
            outputs[name] = result
            if result.failure? && failed_name.nil?
              failed_name = name
              failed_result = result
            end
          end
        end

        build_run_result(outputs, trace,
          failed_name ? :failed : :completed,
          failed_name ? {failed_node: failed_name, step_error: failed_result.error} : nil)
      end

      def deadline_passed?(deadline)
        deadline && @clock.monotonic_now >= deadline
      end

      def build_run_result(outputs, trace, status, error)
        RunResult.new(
          status: status,
          workflow_id: nil,
          outputs: outputs,
          trace: trace,
          error: error,
          waiting_nodes: []
        )
      end

      # Callback ordering contract: every runnable :start in a layer fires
      # before any :finish in that layer, so a consumer logging "layer
      # begins" on the first :start sees a coherent sequence. Skipped
      # steps have no :start — they finish immediately after the runnable
      # :start batch. Strategy is picked before any callback fires, so a
      # consumer querying strategy identity from inside :start sees the
      # one actually running.
      def execute_layer(layer, layer_index, previous_outputs, statuses, trace, deadline)
        runnable, immediate_results = partition_layer(layer, previous_outputs, statuses, deadline)
        results = {}

        runnable.each { |t| @callbacks.start(t.name, t.step) }
        record_immediate_results(immediate_results, results, statuses, layer_index, trace)
        run_tasks(runnable, layer_index, trace, results, statuses)

        results
      end

      def partition_layer(layer, previous_outputs, statuses, deadline)
        runnable = []
        immediate_results = []

        layer.each do |name|
          step = @registry[name]
          condition_context = resolve_condition_context(name, previous_outputs, statuses)
          input = extract_input(condition_context)
          input_keys = input.keys.sort

          begin
            if skip?(step, condition_context)
              immediate_results << [name, record_skip_result, input_keys, :skipped]
            else
              execution = build_step_execution(name, current_attempt: 1, deadline: deadline)
              runnable << Parallel::Task.new(
                name: name,
                step: step,
                input: input,
                attempt: build_step_attempt(step, input, execution),
                execution: execution,
                input_keys: input_keys
              )
            end
          rescue => e
            immediate_results << [name, Result.exception_failure(:run_if_error, e,
              message: "run_if for step #{name} raised: #{e.message}"), input_keys, nil]
          end
        end

        [runnable, immediate_results]
      end

      # Short-circuits on an empty task list (a layer in which every step
      # was filtered by `run_if`): no point handing an empty array to the
      # strategy, and it keeps the trace ordering tidy.
      def run_tasks(tasks, layer_index, trace, results, statuses)
        return if tasks.empty?

        input_keys_by_name = tasks.to_h { |t| [t.name, t.input_keys] }

        @strategy.execute(tasks) do |name, result, started_at, finished_at, duration_ms|
          entry = build_trace_entry(name, layer_index, result,
            started_at: started_at, finished_at: finished_at, duration_ms: duration_ms,
            input_keys: input_keys_by_name.fetch(name))
          trace << entry
          statuses[name] = entry.status
          @callbacks.finish(name, result)
          results[name] = result
        end
      end

      def build_step_execution(name, current_attempt:, deadline:)
        StepExecution.new(
          workflow_id: nil,
          node_path: [name],
          attempt: current_attempt,
          deadline: deadline,
          depth: 0,
          parallel: @strategy.name,
          execution_store: nil,
          event_bus: nil
        )
      end

      def build_step_attempt(step, input, execution)
        chain = @middleware.reverse.reduce(core_step_invoker(step)) do |next_step, middleware|
          build_middleware_invoker(middleware, next_step)
        end

        -> { chain.call(step, input, context: @context, execution: execution) }
      end

      def core_step_invoker(step)
        executor = executor_class(step.type).new
        ->(current_step, current_input, context:, execution:) do
          invoke_step_executor(executor, current_step, current_input, context: context)
        end
      end

      def invoke_step_executor(executor, step, input, context:)
        call_method = executor.method(:call)
        if accepts_context_keyword?(call_method)
          executor.call(step, input, context: context)
        else
          executor.call(step, input)
        end
      end

      def accepts_context_keyword?(call_method)
        call_method.parameters.any? { |kind, name| [:key, :keyreq].include?(kind) && name == :context } ||
          call_method.parameters.any? { |kind, _name| kind == :keyrest }
      end

      def build_middleware_invoker(middleware, next_step)
        ->(step, input, context:, execution:) do
          result = middleware.call(step, input, context: context, execution: execution, next_step: next_step)
          validate_middleware_result!(middleware, step, result)
        end
      end

      def validate_middleware_result!(middleware, step, result)
        return result if result.is_a?(Result)

        Failure.new(error: {
          code: :middleware_bad_return,
          message: "middleware #{middleware.class} returned #{result.class} for step #{step.name} instead of a DAG::Result",
          middleware: middleware.class.name,
          returned_class: result.class.name
        })
      end

      def skip?(step, condition_context) = !Condition.evaluate(step.config[:run_if], condition_context)

      def record_immediate_results(entries, results, statuses, layer_index, trace)
        entries.each do |name, result, input_keys, status|
          entry = build_trace_entry(name, layer_index, result,
            started_at: nil, finished_at: nil, duration_ms: 0,
            input_keys: input_keys, status: status)
          trace << entry
          statuses[name] = entry.status
          @callbacks.finish(name, result)
          results[name] = result
        end
      end

      def record_skip_result = Success.new(value: nil)

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
      def resolve_condition_context(name, outputs, statuses)
        @graph.each_predecessor(name).to_h do |dep|
          [dep, {value: outputs.fetch(dep).value, status: statuses.fetch(dep)}]
        end
      end

      def extract_input(condition_context)
        condition_context.transform_values { |entry| entry[:value] }
      end

      def validate_coverage!(graph, registry)
        missing = graph.nodes.reject { |node| registry.key?(node) }
        return if missing.empty?

        raise ValidationError, "Missing steps for graph nodes: #{missing.sort.join(", ")}"
      end

      def validate_workflow!(graph, registry)
        Validator.validate!(graph, registry)
      end
    end
  end
end
