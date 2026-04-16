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
          schedule_policy = SchedulePolicy.new(step, clock: @clock)

          begin
            input_keys = @dependency_input_resolver.input_keys_for(name: name, step: step)

            if schedule_policy.waiting?
              waiting_nodes << @execution_persistence.node_path_for(name)
              @execution_persistence.persist_waiting_node(name)
            elsif schedule_policy.expired?
              result = schedule_policy.deadline_exceeded_result(name)
              @execution_persistence.persist_expired_schedule_node(name, result.error)
              immediate_results << ImmediateResult.new(name: name, result: result, input_keys: input_keys, status: :failure)
            elsif skip?(step, build_condition_context(name, step, previous_outputs, statuses))
              immediate_results << ImmediateResult.new(name: name, result: record_skip_result, input_keys: input_keys, status: :skipped)
            else
              input = @dependency_input_resolver.resolve(name: name, step: step, outputs: previous_outputs)
              if (reused_result = @execution_persistence.load_reusable_result(name, schedule_policy: schedule_policy))
                immediate_results << ImmediateResult.new(name: name, result: reused_result, input_keys: input_keys, status: :success)
              else
                runnable << @task_builder.call(name: name, step: step, input: input, input_keys: input_keys, deadline: deadline)
              end
            end
          rescue DependencyInputResolver::MissingExecutionStoreError => e
            immediate_results << failure_result(name, :versioned_dependency_requires_execution_store, e.message,
              dependency_name: e.dependency_name, version: e.version)
          rescue DependencyInputResolver::MissingCrossWorkflowResolverError => e
            immediate_results << failure_result(name, :cross_workflow_resolver_missing, e.message,
              workflow_id: e.workflow_id, node_name: e.node_name, version: e.version)
          rescue DependencyInputResolver::MissingVersionError => e
            immediate_results << failure_result(name, :missing_dependency_version, e.message,
              dependency_name: e.dependency_name, version: e.version)
          rescue DependencyInputResolver::WaitingForDependencyError
            waiting_nodes << @execution_persistence.node_path_for(name)
            @execution_persistence.persist_waiting_node(name)
          rescue DependencyInputResolver::ResolverError => e
            immediate_results << failure_result(name, :cross_workflow_resolution_failed, e.message,
              workflow_id: e.workflow_id, node_name: e.node_name, version: e.version)
          rescue => e
            immediate_results << ImmediateResult.new(
              name: name,
              result: Result.exception_failure(:layer_admission_error, e,
                message: "layer admission for step #{name} raised #{e.class}: #{e.message}"),
              input_keys: [],
              status: :failure
            )
          end
        end

        LayerPartition.new(runnable: runnable, immediate_results: immediate_results, waiting_nodes: waiting_nodes)
      end

      private

      def failure_result(name, code, message, **extra)
        ImmediateResult.new(
          name: name,
          result: Failure.new(error: {code: code, message: message}.merge(extra.compact)),
          input_keys: [],
          status: :failure
        )
      end

      def skip?(step, condition_context)
        run_if = step.config[:run_if]
        return !run_if.call(condition_context) if Condition.callable?(run_if)

        !Condition.evaluate(run_if, condition_context)
      end

      def record_skip_result = Success.new(value: nil)

      def dependency_outputs_ready?(name, outputs)
        @graph.each_predecessor(name).all? { |dep| outputs.key?(dep) }
      end

      def build_condition_context(name, step, outputs, statuses)
        run_if = step.config[:run_if]
        if Condition.callable?(run_if)
          @dependency_input_resolver.callable_input_for(name: name, step: step, outputs: outputs, statuses: statuses)
        else
          @dependency_input_resolver.condition_context_for(name: name, step: step, outputs: outputs, statuses: statuses, condition: run_if)
        end
      end
    end
  end
end
