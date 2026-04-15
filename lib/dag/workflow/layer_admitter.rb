# frozen_string_literal: true

module DAG
  module Workflow
    class LayerAdmitter
      def initialize(graph:, registry:, clock:, execution_persistence:, dependency_input_resolver:, root_input:, task_builder:)
        @graph = graph
        @registry = registry
        @clock = clock
        @execution_persistence = execution_persistence
        @dependency_input_resolver = dependency_input_resolver
        @root_input = root_input
        @task_builder = task_builder
      end

      def call(layer:, previous_outputs:, statuses:, deadline:)
        runnable = []
        immediate_results = []
        waiting_nodes = []

        layer.each do |name|
          next unless dependency_outputs_ready?(name, previous_outputs)

          step = @registry[name]

          begin
            input_keys = @dependency_input_resolver.input_keys_for(name: name, step: step)
            if skip?(step, build_condition_context(name, step, previous_outputs, statuses))
              immediate_results << ImmediateResult.new(name: name, result: record_skip_result, input_keys: input_keys, status: :skipped)
              next
            end

            input = @dependency_input_resolver.resolve(name: name, step: step, outputs: previous_outputs)
            schedule_policy = SchedulePolicy.new(step, clock: @clock)

            if schedule_policy.waiting?
              waiting_nodes << @execution_persistence.node_path_for(name)
              @execution_persistence.persist_waiting_node(name)
            elsif schedule_policy.expired?
              result = schedule_policy.deadline_exceeded_result(name)
              @execution_persistence.persist_expired_schedule_node(name, result.error)
              immediate_results << ImmediateResult.new(name: name, result: result, input_keys: input_keys, status: nil)
            elsif (reused_result = @execution_persistence.load_reusable_result(name))
              immediate_results << ImmediateResult.new(name: name, result: reused_result, input_keys: input_keys, status: :success)
            else
              runnable << @task_builder.call(name: name, step: step, input: input, input_keys: input_keys, deadline: deadline)
            end
          rescue DependencyInputResolver::MissingExecutionStoreError => e
            immediate_results << failure_result(name, :versioned_dependency_requires_execution_store, e.message)
          rescue DependencyInputResolver::MissingVersionError => e
            immediate_results << failure_result(name, :missing_dependency_version, e.message)
          rescue DependencyInputResolver::WaitingForDependencyError
            waiting_nodes << @execution_persistence.node_path_for(name)
            @execution_persistence.persist_waiting_node(name)
          rescue DependencyInputResolver::ResolverError => e
            immediate_results << failure_result(name, :cross_workflow_resolution_failed, e.message)
          rescue => e
            immediate_results << ImmediateResult.new(
              name: name,
              result: Result.exception_failure(:run_if_error, e,
                message: "run_if for step #{name} raised: #{e.message}"),
              input_keys: [],
              status: nil
            )
          end
        end

        LayerPartition.new(runnable: runnable, immediate_results: immediate_results, waiting_nodes: waiting_nodes)
      end

      private

      def failure_result(name, code, message)
        ImmediateResult.new(
          name: name,
          result: Failure.new(error: {
            code: code,
            message: message
          }),
          input_keys: [],
          status: nil
        )
      end

      def skip?(step, condition_context) = !Condition.evaluate(step.config[:run_if], condition_context)

      def record_skip_result = Success.new(value: nil)

      def dependency_outputs_ready?(name, outputs)
        @graph.each_predecessor(name).all? { |dep| outputs.key?(dep) }
      end

      def build_condition_context(name, step, outputs, statuses)
        if Condition.callable?(step.config[:run_if])
          basic_condition_context(name, outputs, statuses)
        else
          @dependency_input_resolver.condition_context_for(name: name, outputs: outputs, statuses: statuses)
        end
      end

      def basic_condition_context(name, outputs, statuses)
        dependency_context = @root_input.transform_values { |value| {value: value, status: :success} }

        dependency_context.merge(@graph.each_predecessor(name).to_h do |dep|
          [dep, {value: outputs.fetch(dep).value, status: statuses.fetch(dep)}]
        end)
      end
    end
  end
end
