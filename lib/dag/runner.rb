# frozen_string_literal: true

require "timeout"
require "open3"

module DAG
  # Executes a validated Graph. Runs each layer in parallel using Ractors
  # (when available and beneficial), falls back to sequential execution.
  #
  #   runner = DAG::Runner.new(graph)
  #   run = runner.call
  #   run.success?                  #=> true
  #   run.value[:parse]             #=> Result with that node's output
  #
  # Options:
  #   parallel: true    — use Ractors for nodes in the same layer (default: true)
  #   on_node_start:    — callback proc called before each node
  #   on_node_finish:   — callback proc called after each node

  class Runner
    def initialize(graph, parallel: true, on_node_start: nil, on_node_finish: nil)
      @graph = graph
      @parallel = parallel
      @on_node_start = on_node_start
      @on_node_finish = on_node_finish
    end

    def call
      layers = @graph.execution_order
      outputs = {} # node_name => Result

      layers.each do |layer|
        results = execute_layer(layer, outputs)

        results.each do |name, result|
          outputs[name] = result

          # Stop the entire DAG on first failure
          return Result.failure({ failed_node: name, error: result.error, outputs: outputs }) if result.failure?
        end
      end

      Result.success(outputs)
    end

    private

    def execute_layer(layer, previous_outputs)
      if @parallel && layer.size > 1 && ractor_available?
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
      # Each Ractor gets a self-contained task: node config + input.
      # We serialize what we need since Ractors can't share mutable objects.
      tasks = layer.map do |name|
        node = @graph.node(name)
        input = gather_input(node, previous_outputs)
        # Pack node data as a shareable hash
        node_data = {
          name: node.name,
          type: node.type,
          config: deep_dup_shareable(node.config)
        }
        [name, node_data, input]
      end

      ractors = tasks.map do |name, node_data, input|
        Ractor.new(name, node_data, input) do |n, nd, inp|
          # Reconstruct inside Ractor
          node = DAG::Node.new(name: nd[:name], type: nd[:type], **nd[:config])
          step = DAG::Steps.for(node.type)
          [n, step.call(node, inp)]
        end
      end

      results = {}
      ractors.each do |r|
        name, result = r.take
        @on_node_finish&.call(name, result)
        results[name] = result
      end
      results
    end

    def execute_node(name, previous_outputs)
      node = @graph.node(name)
      input = gather_input(node, previous_outputs)

      @on_node_start&.call(name, node)

      step = Steps.for(node.type)
      result = step.call(node, input)

      @on_node_finish&.call(name, result)
      result
    end

    # Merge outputs from dependency nodes into a single input.
    # If one dependency: pass its value directly.
    # If multiple: pass a hash { dep_name => value }.
    def gather_input(node, outputs)
      deps = node.depends_on
      return nil if deps.empty?
      return outputs[deps.first]&.value if deps.size == 1

      deps.each_with_object({}) do |dep, h|
        h[dep] = outputs[dep]&.value
      end
    end

    def ractor_available?
      defined?(Ractor) && Ractor.respond_to?(:new)
    end

    # Deep-dup a hash into primitives that Ractors can share
    def deep_dup_shareable(obj)
      case obj
      when Hash then obj.transform_keys(&:to_sym).transform_values { |v| deep_dup_shareable(v) }
      when Array then obj.map { |v| deep_dup_shareable(v) }
      when String then obj.dup.freeze
      when Symbol, Integer, Float, NilClass, TrueClass, FalseClass then obj
      else obj.to_s.freeze
      end
    end
  end
end
