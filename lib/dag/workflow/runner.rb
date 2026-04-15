# frozen_string_literal: true

require "etc"

module DAG
  module Workflow
    TraceEntry = Data.define(:name, :layer, :started_at, :finished_at, :duration_ms, :status, :input_keys, :attempt, :retried) do
      def initialize(name:, layer:, started_at:, finished_at:, duration_ms:, status:, input_keys:, attempt: 1, retried: false)
        super
      end
    end

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
        workflow_id: nil,
        execution_store: nil,
        node_path_prefix: [],
        root_input: {},
        register_execution_store: true,
        on_step_start: nil, on_step_finish: nil)
        graph, registry, definition_source_path = unpack_definition(graph_or_definition, registry)
        @graph = graph
        @registry = registry
        @definition_source_path = definition_source_path
        @timeout = timeout
        @clock = clock
        @context = context
        @middleware = Array(middleware).freeze
        @workflow_id = workflow_id
        @execution_store = execution_store
        @node_path_prefix = Array(node_path_prefix).map(&:to_sym).freeze
        @root_input = root_input.transform_keys(&:to_sym).freeze
        @register_execution_store = register_execution_store
        validate_context_parallelism!(parallel, context)
        @callbacks = RunCallbacks.new(on_step_start: on_step_start, on_step_finish: on_step_finish)
        @strategy = build_strategy(parallel, max_parallelism)
        validate_coverage!(graph, registry)
        validate_workflow!(graph, registry)
        validate_durable_execution!
        @definition_fingerprint = @execution_store ? DefinitionFingerprint.for(Definition.new(graph: @graph, registry: @registry, source_path: @definition_source_path)) : nil
      end

      def call
        call_with_initial_outputs({})
      end

      def call_with_initial_outputs(initial_outputs)
        deadline = @timeout ? @clock.monotonic_now + @timeout : nil
        prepare_execution_store!
        execute_layers(@graph.topological_layers, deadline, initial_outputs: initial_outputs)
      end

      private

      def validate_durable_execution!
        return unless @execution_store

        raise ValidationError, "Runner requires workflow_id when execution_store is enabled" if @workflow_id.nil? || @workflow_id.to_s.empty?
      end

      def prepare_execution_store!
        return unless @execution_store && @register_execution_store

        existing = @execution_store.load_run(@workflow_id)
        if existing && existing[:definition_fingerprint] != @definition_fingerprint
          raise ValidationError,
            "Stored fingerprint for workflow_id #{@workflow_id.inspect} does not match the current definition fingerprint"
        end

        @execution_store.begin_run(
          workflow_id: @workflow_id,
          definition_fingerprint: @definition_fingerprint,
          node_paths: @graph.topological_sort.map { |name| node_path_for(name) }
        )
      end

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
          [graph.graph, graph.registry, graph.source_path]
        else
          raise ArgumentError, "Runner.new(graph, registry) requires a registry" if registry.nil?
          [graph, registry, nil]
        end
      end

      def executor_class(type) = Steps.class_for(type)

      def execute_layers(layers, deadline, initial_outputs: {})
        outputs = normalize_initial_outputs(initial_outputs)
        statuses = outputs.transform_values { |_result| :success }
        trace = []
        failed_name = nil
        failed_result = nil
        paused = false

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

          if pause_requested?
            paused = true
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

        status = if failed_name
          :failed
        elsif paused
          :paused
        else
          :completed
        end

        build_run_result(outputs, trace,
          status,
          failed_name ? {failed_node: failed_name, step_error: failed_result.error} : nil)
      end

      def deadline_passed?(deadline)
        deadline && @clock.monotonic_now >= deadline
      end

      def build_run_result(outputs, trace, status, error)
        @execution_store&.set_workflow_status(workflow_id: @workflow_id, status: status, waiting_nodes: [])

        RunResult.new(
          status: status,
          workflow_id: @workflow_id,
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
            elsif (reused_result = load_reusable_result(name))
              immediate_results << [name, reused_result, input_keys, :success]
            else
              execution = build_step_execution(name, current_attempt: 1, deadline: deadline)
              attempt_log = []
              runnable << Parallel::Task.new(
                name: name,
                step: step,
                input: input,
                attempt: build_step_attempt(step, input, execution, attempt_log),
                execution: execution,
                input_keys: input_keys,
                attempt_log: attempt_log
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

        tasks_by_name = tasks.to_h { |task| [task.name, task] }

        @strategy.execute(tasks) do |name, result, started_at, finished_at, duration_ms|
          task = tasks_by_name.fetch(name)
          entries = build_trace_entries_for_task(task, layer_index, result,
            started_at: started_at, finished_at: finished_at, duration_ms: duration_ms)
          trace.concat(entries)
          persist_step_result!(task, result, entries)
          statuses[name] = entries.last.status
          @callbacks.finish(name, result)
          results[name] = result
        end
      end

      def build_step_execution(name, current_attempt:, deadline:)
        StepExecution.new(
          workflow_id: @workflow_id,
          node_path: node_path_for(name),
          attempt: current_attempt,
          deadline: deadline,
          depth: @node_path_prefix.length,
          parallel: @strategy.name,
          execution_store: @execution_store,
          event_bus: nil
        )
      end

      def build_step_attempt(step, input, execution, attempt_log)
        chain = @middleware.reverse.reduce(core_step_invoker(step, attempt_log)) do |next_step, middleware|
          build_middleware_invoker(middleware, next_step)
        end

        -> { chain.call(step, input, context: @context, execution: execution) }
      end

      def core_step_invoker(step, attempt_log)
        executor = (step.type == :sub_workflow) ? nil : executor_class(step.type).new
        ->(current_step, current_input, context:, execution:) do
          started_at = @clock.monotonic_now
          result = if current_step.type == :sub_workflow
            run_sub_workflow_step(current_step, current_input, context: context, execution: execution)
          else
            invoke_step_executor(executor, current_step, current_input, context: context)
          end
          unless result.is_a?(Result)
            result = Failure.new(error: {
              code: :step_bad_return,
              message: "step #{current_step.name} returned #{result.class} instead of a DAG::Result. " \
                       "Wrap the value in DAG::Success.new(value: ...) or DAG::Failure.new(error: ...).",
              returned_class: result.class.name,
              strategy: @strategy.name
            })
          end
          result, child_trace = unwrap_sub_workflow_result(result)
          attempt_log.concat(child_trace)
          finished_at = @clock.monotonic_now
          attempt_log << {
            attempt: execution.attempt,
            node_path: execution.node_path,
            started_at: started_at,
            finished_at: finished_at,
            duration_ms: ((finished_at - started_at) * 1000).round(2),
            status: result.success? ? :success : :failure,
            retried: false
          }
          result
        rescue => e
          finished_at = @clock.monotonic_now
          failure = Result.exception_failure(:step_raised, e,
            message: "step #{current_step.name} raised: #{e.message}",
            strategy: @strategy.name)
          attempt_log << {
            attempt: execution.attempt,
            node_path: execution.node_path,
            started_at: started_at,
            finished_at: finished_at,
            duration_ms: ((finished_at - started_at) * 1000).round(2),
            status: :failure,
            retried: false
          }
          failure
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

      def run_sub_workflow_step(step, input, context:, execution:)
        definition_result = resolve_sub_workflow_definition(step)
        return definition_result if definition_result.is_a?(Failure)

        definition = definition_result.value
        mapped_input = map_sub_workflow_input(step, input)
        register_child_node_paths(definition, execution)

        child_result = Runner.new(definition,
          parallel: execution.parallel,
          max_parallelism: @strategy.max_parallelism,
          timeout: remaining_timeout_for(execution.deadline),
          clock: @clock,
          context: context,
          middleware: @middleware,
          workflow_id: execution.workflow_id,
          execution_store: execution.execution_store,
          node_path_prefix: execution.node_path,
          root_input: mapped_input,
          register_execution_store: false).call

        if child_result.failure?
          return Failure.new(error: {
            code: :sub_workflow_failed,
            message: "sub_workflow step #{step.name} failed",
            child_error: child_result.error,
            child_trace: child_result.trace
          })
        end

        selected_output = select_sub_workflow_output(step, definition, child_result.outputs)
        return selected_output if selected_output.is_a?(Failure)

        Success.new(value: {
          __sub_workflow_output__: selected_output,
          __sub_workflow_trace__: child_result.trace
        })
      end

      def register_child_node_paths(definition, execution)
        return unless execution.execution_store && execution.workflow_id

        fingerprint = execution.execution_store.load_run(execution.workflow_id)&.fetch(:definition_fingerprint)
        execution.execution_store.begin_run(
          workflow_id: execution.workflow_id,
          definition_fingerprint: fingerprint || @definition_fingerprint,
          node_paths: definition.graph.topological_sort.map { |name| execution.node_path + [name] }
        )
      end

      def resolve_sub_workflow_definition(step)
        definition = step.config[:definition]
        definition_path = step.config[:definition_path]

        if definition.is_a?(Definition) && blank?(definition_path)
          return Success.new(value: definition)
        end

        if definition.nil? && !blank?(definition_path)
          return Success.new(value: Loader.from_file(resolve_sub_workflow_path(definition_path)))
        end

        Failure.new(error: {
          code: :sub_workflow_invalid_definition,
          message: "sub_workflow step #{step.name} must define exactly one of definition or definition_path"
        })
      rescue ArgumentError, ValidationError => e
        Failure.new(error: {
          code: :sub_workflow_invalid_definition,
          message: e.message
        })
      end

      def resolve_sub_workflow_path(definition_path)
        return definition_path if Pathname.new(definition_path).absolute?

        base_dir = @definition_source_path && File.dirname(@definition_source_path)
        File.expand_path(definition_path, base_dir || Dir.pwd)
      end

      def remaining_timeout_for(deadline)
        return nil unless deadline

        remaining = deadline - @clock.monotonic_now
        remaining.positive? ? remaining : 0
      end

      def map_sub_workflow_input(step, input)
        mapping = step.config[:input_mapping]
        return input unless mapping

        mapping.each_with_object({}) do |(from, to), mapped|
          mapped[to.to_sym] = input.fetch(from.to_sym)
        end
      end

      def select_sub_workflow_output(step, definition, outputs)
        leaves = definition.graph.leaves.to_a.sort
        output_key = step.config[:output_key]&.to_sym

        if output_key
          unless leaves.include?(output_key)
            raise ValidationError,
              "sub_workflow step #{step.name} output_key #{output_key.inspect} must reference a leaf node (leaves: #{leaves.inspect})"
          end

          return outputs.fetch(output_key).value
        end

        leaves.to_h { |leaf| [leaf, outputs.fetch(leaf).value] }
      rescue ValidationError => e
        Failure.new(error: {
          code: :sub_workflow_invalid_output_key,
          message: e.message
        })
      end

      def unwrap_sub_workflow_result(result)
        if result.success? && result.value.is_a?(Hash) && result.value[:__sub_workflow_output__]
          [Success.new(value: result.value[:__sub_workflow_output__]), result.value[:__sub_workflow_trace__] || []]
        elsif result.failure? && result.error.is_a?(Hash) && result.error[:child_trace]
          [Failure.new(error: result.error.except(:child_trace)), result.error[:child_trace] || []]
        else
          [result, []]
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
          entry = build_trace_entry(node_path_for(name), layer_index, result,
            started_at: nil, finished_at: nil, duration_ms: 0,
            input_keys: input_keys, status: status)
          trace << entry
          statuses[name] = entry.status
          @callbacks.finish(name, result)
          results[name] = result
        end
      end

      def record_skip_result = Success.new(value: nil)

      def node_path_for(name)
        @node_path_prefix + [name.to_sym]
      end

      def trace_name_for(node_path)
        path = Array(node_path).map(&:to_sym)
        return path.first if path.length == 1

        path.join(".").to_sym
      end

      def pause_requested?
        @execution_store && @workflow_id && @execution_store.load_run(@workflow_id)&.fetch(:paused, false)
      end

      def blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      def normalize_initial_outputs(initial_outputs)
        initial_outputs.transform_values do |value|
          value.is_a?(Result) ? value : Success.new(value: value)
        end
      end

      def load_reusable_result(name)
        return nil unless @execution_store

        stored = @execution_store.load_output(workflow_id: @workflow_id, node_path: node_path_for(name))
        stored && stored[:result]
      end

      def persist_step_result!(task, result, entries)
        return unless @execution_store

        entries.each do |entry|
          @execution_store.append_trace(workflow_id: @workflow_id, entry: entry)
        end

        if result.success?
          @execution_store.set_node_state(workflow_id: @workflow_id, node_path: task.execution.node_path, state: :completed)
          @execution_store.save_output(
            workflow_id: @workflow_id,
            node_path: task.execution.node_path,
            version: task.execution.attempt,
            result: result,
            reusable: true,
            superseded: false
          )
        else
          @execution_store.set_node_state(
            workflow_id: @workflow_id,
            node_path: task.execution.node_path,
            state: :failed,
            reason: result.error,
            metadata: {}
          )
        end
      end

      def build_trace_entries_for_task(task, layer_index, result, started_at:, finished_at:, duration_ms:)
        if task.attempt_log.empty?
          return [build_trace_entry(task.execution.node_path, layer_index, result,
            started_at: started_at, finished_at: finished_at, duration_ms: duration_ms,
            input_keys: task.input_keys)]
        end

        task.attempt_log.each_with_index.map do |entry, index|
          next entry if entry.is_a?(TraceEntry)

          build_trace_entry(entry[:node_path] || task.execution.node_path, layer_index, result,
            started_at: entry[:started_at],
            finished_at: entry[:finished_at],
            duration_ms: entry[:duration_ms],
            input_keys: entry[:input_keys] || task.input_keys,
            status: entry[:status],
            attempt: entry[:attempt],
            retried: index < (task.attempt_log.length - 1))
        end
      end

      def build_trace_entry(node_path, layer_index, result, started_at:, finished_at:, duration_ms:, input_keys:, status: nil, attempt: 1, retried: false)
        TraceEntry.new(
          name: trace_name_for(node_path), layer: layer_index,
          started_at: started_at, finished_at: finished_at,
          duration_ms: duration_ms,
          status: status || (result.success? ? :success : :failure),
          input_keys: input_keys,
          attempt: attempt,
          retried: retried
        )
      end

      # Predecessors always have a Result in `outputs` by the time we
      # resolve a downstream layer — skipped steps still record Success(nil).
      def resolve_condition_context(name, outputs, statuses)
        dependency_context = @root_input.transform_values { |value| {value: value, status: :success} }

        dependency_context.merge(@graph.each_predecessor(name).to_h do |dep|
          [dep, {value: outputs.fetch(dep).value, status: statuses.fetch(dep)}]
        end)
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
