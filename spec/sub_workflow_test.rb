# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class SubWorkflowTest < Minitest::Test
  include TestHelpers

  def test_yaml_sub_workflow_definition_path_executes_child_workflow_from_parent_file
    Dir.mktmpdir("dag-subworkflow") do |dir|
      child_path = File.join(dir, "child.yml")
      File.write(child_path, <<~YAML)
        nodes:
          summarize:
            type: exec
            command: "printf yaml-child"
      YAML

      parent_path = File.join(dir, "parent.yml")
      File.write(parent_path, <<~YAML)
        nodes:
          process:
            type: sub_workflow
            definition_path: child.yml
            output_key: summarize
      YAML

      definition = DAG::Workflow::Loader.from_file(parent_path)
      result = DAG::Workflow::Runner.new(definition, parallel: false).call

      assert result.success?
      assert_equal "yaml-child", result.outputs[:process].value
      assert_includes result.trace.map(&:name), :"process.summarize"
    end
  end

  def test_nested_definition_paths_resolve_relative_to_each_caller_file
    Dir.mktmpdir("dag-subworkflow-nested") do |dir|
      workflows_dir = File.join(dir, "workflows")
      nested_dir = File.join(workflows_dir, "nested")
      FileUtils.mkdir_p(nested_dir)

      File.write(File.join(nested_dir, "grandchild.yml"), <<~YAML)
        nodes:
          summarize:
            type: exec
            command: "printf nested-child"
      YAML

      File.write(File.join(workflows_dir, "child.yml"), <<~YAML)
        nodes:
          nested:
            type: sub_workflow
            definition_path: nested/grandchild.yml
            output_key: summarize
      YAML

      parent_path = File.join(dir, "parent.yml")
      File.write(parent_path, <<~YAML)
        nodes:
          process:
            type: sub_workflow
            definition_path: workflows/child.yml
            output_key: nested
      YAML

      definition = DAG::Workflow::Loader.from_file(parent_path)
      result = DAG::Workflow::Runner.new(definition, parallel: false).call

      assert result.success?
      assert_equal "nested-child", result.outputs[:process].value
      assert_includes result.trace.map(&:name), :"process.nested.summarize"
    end
  end

  def test_sub_workflow_requires_exactly_one_definition_source
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        process: {
          type: :sub_workflow,
          output_key: :done
        }
      )
    end

    assert_match(/exactly one/, error.message)
  end

  def test_sub_workflow_rejects_both_definition_and_definition_path
    child = DAG::Workflow::Loader.from_hash(done: {type: :exec, command: "printf ok"})

    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        process: {
          type: :sub_workflow,
          definition: child,
          definition_path: "child.yml",
          output_key: :done
        }
      )
    end

    assert_match(/exactly one/, error.message)
  end

  def test_programmatic_sub_workflow_returns_child_leaf_outputs_and_namespaced_trace
    child = DAG::Workflow::Loader.from_hash(
      analyze: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: input[:raw].upcase) }
      },
      summarize: {
        type: :ruby,
        depends_on: [:analyze],
        callable: ->(input) { DAG::Success.new(value: "#{input[:analyze]}!") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch],
        input_mapping: {fetch: :raw}
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false).call

    assert result.success?
    assert_equal({summarize: "HELLO!"}, result.outputs[:process].value)
    assert_includes result.trace.map(&:name), :"process.analyze"
    assert_includes result.trace.map(&:name), :"process.summarize"
  end

  def test_sub_workflow_output_key_returns_selected_leaf_value
    child = DAG::Workflow::Loader.from_hash(
      analyze: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: input[:raw].upcase) }
      },
      summarize: {
        type: :ruby,
        depends_on: [:analyze],
        callable: ->(input) { DAG::Success.new(value: "#{input[:analyze]}!") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch],
        input_mapping: {fetch: :raw},
        output_key: :summarize
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false).call

    assert result.success?
    assert_equal "HELLO!", result.outputs[:process].value
  end

  def test_sub_workflow_rejects_non_leaf_output_key
    child = DAG::Workflow::Loader.from_hash(
      analyze: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: input[:raw].upcase) }
      },
      summarize: {
        type: :ruby,
        depends_on: [:analyze],
        callable: ->(input) { DAG::Success.new(value: "#{input[:analyze]}!") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch],
        input_mapping: {fetch: :raw},
        output_key: :analyze
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false).call

    assert result.failure?
    assert_equal :process, result.error[:failed_node]
    assert_equal :sub_workflow_invalid_output_key, result.error[:step_error][:code]
  end

  def test_select_sub_workflow_output_returns_leaf_missing_failure_when_named_leaf_absent
    child = DAG::Workflow::Loader.from_hash(
      analyze: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: 1) }
      },
      summarize: {
        type: :ruby,
        depends_on: [:analyze],
        callable: ->(input) { DAG::Success.new(value: input[:analyze]) }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      process: {
        type: :sub_workflow,
        definition: child,
        output_key: :summarize
      }
    )

    runner = DAG::Workflow::Runner.new(parent, parallel: false)
    step = parent.registry[:process]
    outputs = {}

    failure = runner.send(:select_sub_workflow_output, step, child, outputs)

    assert_kind_of DAG::Failure, failure
    assert_equal :sub_workflow_leaf_missing, failure.error[:code]
    assert_equal :summarize, failure.error[:missing_leaf]
    assert_equal [], failure.error[:available_outputs]
  end

  def test_select_sub_workflow_output_returns_leaf_missing_failure_when_implicit_leaf_absent
    child = DAG::Workflow::Loader.from_hash(
      a: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: 1) }
      },
      b: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: 2) }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      process: {
        type: :sub_workflow,
        definition: child
      }
    )

    runner = DAG::Workflow::Runner.new(parent, parallel: false)
    step = parent.registry[:process]
    outputs = {a: DAG::Success.new(value: 1)}

    failure = runner.send(:select_sub_workflow_output, step, child, outputs)

    assert_kind_of DAG::Failure, failure
    assert_equal :sub_workflow_leaf_missing, failure.error[:code]
    assert_equal :b, failure.error[:missing_leaf]
    assert_equal [:a], failure.error[:available_outputs]
  end

  def test_sub_workflow_propagates_waiting_status_and_namespaced_waiting_nodes
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)

    child = DAG::Workflow::Loader.from_hash(
      gated: {
        type: :ruby,
        schedule: {not_before: future_time},
        callable: ->(_input) { DAG::Success.new(value: "later") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch]
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false, clock: clock).call

    assert_equal :waiting, result.status
    assert_equal "hello", result.outputs[:fetch].value
    refute result.outputs.key?(:process)
    assert_equal [[:process, :gated]], result.waiting_nodes
    refute_includes result.trace.map(&:name), :process
    refute_includes result.trace.map(&:name), :"process.gated"
  end

  def test_sub_workflow_waiting_still_fires_finish_callback_with_nil_success
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)
    started = []
    finished = []

    child = DAG::Workflow::Loader.from_hash(
      gated: {
        type: :ruby,
        schedule: {not_before: future_time},
        callable: ->(_input) { DAG::Success.new(value: "later") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      process: {
        type: :sub_workflow,
        definition: child
      }
    )

    result = DAG::Workflow::Runner.new(parent,
      parallel: false,
      clock: clock,
      on_step_start: ->(name, _step) { started << name },
      on_step_finish: ->(name, callback_result) { finished << [name, callback_result] }).call

    assert_equal :waiting, result.status
    assert_equal [:process], started
    assert_equal 1, finished.size
    assert_equal :process, finished.first[0]
    assert_kind_of DAG::Success, finished.first[1]
    assert_nil finished.first[1].value
    refute result.outputs.key?(:process)
  end

  def test_sub_workflow_propagates_paused_status_without_parent_output
    store = build_memory_store

    child = DAG::Workflow::Loader.from_hash(
      inner_fetch: {
        type: :ruby,
        resume_key: "inner-fetch-v1",
        callable: ->(_input) do
          store.set_pause_flag(workflow_id: "wf-child-pause", paused: true)
          DAG::Success.new(value: "raw")
        end
      },
      inner_transform: {
        type: :ruby,
        depends_on: [:inner_fetch],
        resume_key: "inner-transform-v1",
        callable: ->(input) { DAG::Success.new(value: input[:inner_fetch].upcase) }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      process: {
        type: :sub_workflow,
        definition: child,
        output_key: :inner_transform,
        resume_key: "process-v1"
      }
    )

    result = DAG::Workflow::Runner.new(parent,
      parallel: false,
      workflow_id: "wf-child-pause",
      execution_store: store).call

    assert_equal :paused, result.status
    assert result.paused?
    refute result.outputs.key?(:process)
    assert_equal [], result.waiting_nodes
    assert_includes result.trace.map(&:name), :"process.inner_fetch"
    refute_includes result.trace.map(&:name), :process
    refute_includes result.trace.map(&:name), :"process.inner_transform"
  end

  def test_sub_workflow_paused_still_fires_finish_callback_with_nil_success
    store = build_memory_store
    started = []
    finished = []

    child = DAG::Workflow::Loader.from_hash(
      inner_fetch: {
        type: :ruby,
        resume_key: "inner-fetch-v1",
        callable: ->(_input) do
          store.set_pause_flag(workflow_id: "wf-child-pause-callback", paused: true)
          DAG::Success.new(value: "raw")
        end
      },
      inner_transform: {
        type: :ruby,
        depends_on: [:inner_fetch],
        resume_key: "inner-transform-v1",
        callable: ->(input) { DAG::Success.new(value: input[:inner_fetch].upcase) }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      process: {
        type: :sub_workflow,
        definition: child,
        output_key: :inner_transform,
        resume_key: "process-v1"
      }
    )

    result = DAG::Workflow::Runner.new(parent,
      parallel: false,
      workflow_id: "wf-child-pause-callback",
      execution_store: store,
      on_step_start: ->(name, _step) { started << name },
      on_step_finish: ->(name, callback_result) { finished << [name, callback_result] }).call

    assert_equal :paused, result.status
    assert_equal [:process], started
    assert_equal 1, finished.size
    assert_equal :process, finished.first[0]
    assert_kind_of DAG::Success, finished.first[1]
    assert_nil finished.first[1].value
    refute result.outputs.key?(:process)
  end

  def test_sub_workflow_uses_parent_context_and_execution_store_namespace
    child_calls = 0
    child = DAG::Workflow::Loader.from_hash(
      inner_fetch: {
        type: :ruby,
        resume_key: "inner-fetch-v1",
        callable: ->(input, context) do
          child_calls += 1
          DAG::Success.new(value: "#{input[:raw]}#{context[:suffix]}")
        end
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      fetch: {
        type: :ruby,
        resume_key: "fetch-v1",
        callable: ->(_input) { DAG::Success.new(value: "hello") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:fetch],
        input_mapping: {fetch: :raw},
        output_key: :inner_fetch,
        resume_key: "process-v1"
      }
    )

    store = build_memory_store
    runner = lambda do
      DAG::Workflow::Runner.new(parent,
        parallel: false,
        context: {suffix: "!"},
        workflow_id: "wf-sub",
        execution_store: store)
    end

    first = runner.call.call
    second = runner.call.call
    run = store.load_run("wf-sub")

    assert first.success?
    assert second.success?
    assert_equal "hello!", first.outputs[:process].value
    assert_equal "hello!", second.outputs[:process].value
    assert_equal 1, child_calls
    assert_includes run[:node_paths], [:process, :inner_fetch]
    assert_equal "hello!", store.load_output(workflow_id: "wf-sub", node_path: [:process, :inner_fetch])[:result].value
  end

  def test_definition_path_supports_durable_execution_fingerprints_and_child_namespaces
    Dir.mktmpdir("dag-subworkflow-store") do |dir|
      File.write(File.join(dir, "child.yml"), <<~YAML)
        nodes:
          summarize:
            type: exec
            command: "printf stored-child"
      YAML

      parent_path = File.join(dir, "parent.yml")
      File.write(parent_path, <<~YAML)
        nodes:
          process:
            type: sub_workflow
            definition_path: child.yml
            output_key: summarize
            resume_key: process-v1
      YAML

      definition = DAG::Workflow::Loader.from_file(parent_path)
      store = build_memory_store

      runner = lambda do
        DAG::Workflow::Runner.new(definition,
          parallel: false,
          workflow_id: "wf-yaml-sub",
          execution_store: store)
      end

      first = runner.call.call
      second = runner.call.call
      run = store.load_run("wf-yaml-sub")

      assert first.success?
      assert second.success?
      assert_equal "stored-child", first.outputs[:process].value
      assert_equal "stored-child", second.outputs[:process].value
      assert_includes run[:node_paths], [:process, :summarize]
      assert_equal "stored-child", store.load_output(workflow_id: "wf-yaml-sub", node_path: [:process, :summarize])[:result].value
    end
  end

  def test_sub_workflow_parent_status_remains_success_when_child_trace_ends_with_skipped_entry
    child = DAG::Workflow::Loader.from_hash(
      prep: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "ready") }
      },
      done: {
        type: :ruby,
        depends_on: [:prep],
        callable: ->(_input) { DAG::Success.new(value: "done") }
      },
      final_skip: {
        type: :ruby,
        depends_on: [:done],
        run_if: {from: :done, value: {equals: "nope"}},
        callable: ->(_input) { DAG::Success.new(value: "skip-me") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      process: {
        type: :sub_workflow,
        definition: child
      },
      downstream: {
        type: :ruby,
        depends_on: [:process],
        run_if: {from: :process, status: :success},
        callable: ->(input) { DAG::Success.new(value: input[:process]) }
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false).call

    assert_equal :completed, result.status
    assert_equal({final_skip: nil}, result.outputs[:process].value)
    assert_equal({final_skip: nil}, result.outputs[:downstream].value)
    assert_equal :success, result.trace.find { |entry| entry.name == :process }.status
    assert_equal :success, result.trace.find { |entry| entry.name == :downstream }.status
  end

  def test_sub_workflow_depth_limit_enforced
    max_depth = 3

    inner_def = DAG::Workflow::Loader.from_hash(
      deep: {type: :exec, command: "printf ok"}
    )

    # Build a chain that exceeds max_depth
    current_def = inner_def
    (max_depth + 2).times do
      child = DAG::Workflow::Loader.from_hash(
        level: {type: :sub_workflow, definition: current_def}
      )
      current_def = child
    end

    outer_def = DAG::Workflow::Loader.from_hash(
      top: {type: :sub_workflow, definition: current_def, max_sub_workflow_depth: max_depth}
    )

    result = DAG::Workflow::Runner.new(outer_def, parallel: false).call

    assert_equal :failed, result.status
    assert_equal :top, result.error[:failed_node]
    # The depth-exceeded Failure is wrapped by each parent sub_workflow step:
    # depth-limit at innermost level -> sub_workflow_failed (level) -> sub_workflow_failed (top)
    assert_equal :sub_workflow_failed, result.error[:step_error][:code]
    assert_equal :sub_workflow_failed, result.error[:step_error][:child_error][:step_error][:code]
    assert_equal :sub_workflow_depth_exceeded,
      result.error[:step_error][:child_error][:step_error][:child_error][:step_error][:code]
    assert_match(/exceeded/,
      result.error[:step_error][:child_error][:step_error][:child_error][:step_error][:message])
  end

  def test_sub_workflow_resolve_definition_catches_load_errors
    parent_def = DAG::Workflow::Loader.from_hash(
      process: {type: :sub_workflow, definition_path: "/nonexistent/path/does/not/exist.yml"}
    )

    result = DAG::Workflow::Runner.new(parent_def, parallel: false).call

    assert_equal :failed, result.status
    assert_equal :process, result.error[:failed_node]
    assert_equal :sub_workflow_invalid_definition, result.error[:step_error][:code]
  end

  def test_sub_workflow_input_mapping_missing_key_returns_failure
    child = DAG::Workflow::Loader.from_hash(
      analyze: {type: :exec, command: "printf ok"}
    )

    parent_def = DAG::Workflow::Loader.from_hash(
      process: {
        type: :sub_workflow,
        definition: child,
        input_mapping: {nonexistent_key: :raw}
      }
    )

    result = DAG::Workflow::Runner.new(parent_def, parallel: false).call

    assert_equal :failed, result.status
    assert_equal :process, result.error[:failed_node]
    assert_equal :sub_workflow_input_missing, result.error[:step_error][:code]
  end

  def test_sub_workflow_waiting_records_blocked_upstream_for_single_downstream
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))

    parent = parent_with_waiting_child_and(downstream: {
      finalize: {
        type: :ruby,
        depends_on: [:process],
        callable: ->(input) { DAG::Success.new(value: "finalized:#{input[:process]}") }
      }
    })

    result = DAG::Workflow::Runner.new(parent, parallel: false, clock: clock).call

    assert_equal :waiting, result.status
    refute result.outputs.key?(:process)
    refute result.outputs.key?(:finalize)

    finalize_entry = result.trace.find { |e| e.name == :finalize }
    refute_nil finalize_entry, "expected blocked_upstream trace entry for :finalize"
    assert_equal :blocked_upstream, finalize_entry.status
  end

  def test_sub_workflow_waiting_propagates_blocked_upstream_transitively
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))

    parent = parent_with_waiting_child_and(downstream: {
      middle: {
        type: :ruby,
        depends_on: [:process],
        callable: ->(input) { DAG::Success.new(value: input[:process]) }
      },
      tail: {
        type: :ruby,
        depends_on: [:middle],
        callable: ->(input) { DAG::Success.new(value: input[:middle]) }
      }
    })

    result = DAG::Workflow::Runner.new(parent, parallel: false, clock: clock).call

    assert_equal :waiting, result.status
    refute result.outputs.key?(:middle)
    refute result.outputs.key?(:tail)

    statuses = result.trace.to_h { |e| [e.name, e.status] }
    assert_equal :blocked_upstream, statuses[:middle]
    assert_equal :blocked_upstream, statuses[:tail]
  end

  def test_sub_workflow_waiting_blocks_only_dependent_branch
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))

    parent = parent_with_waiting_child_and(downstream: {
      blocked_branch: {
        type: :ruby,
        depends_on: [:process],
        callable: ->(input) { DAG::Success.new(value: input[:process]) }
      },
      independent_root: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "indep") }
      },
      independent_leaf: {
        type: :ruby,
        depends_on: [:independent_root],
        callable: ->(input) { DAG::Success.new(value: "leaf:#{input[:independent_root]}") }
      }
    })

    result = DAG::Workflow::Runner.new(parent, parallel: false, clock: clock).call

    assert_equal :waiting, result.status
    assert_equal "indep", result.outputs[:independent_root].value
    assert_equal "leaf:indep", result.outputs[:independent_leaf].value
    refute result.outputs.key?(:blocked_branch)

    blocked_entry = result.trace.find { |e| e.name == :blocked_branch }
    refute_nil blocked_entry
    assert_equal :blocked_upstream, blocked_entry.status
  end

  def test_sub_workflow_waiting_blocks_diamond_join_when_one_branch_waits
    clock = build_clock(wall_time: Time.utc(2026, 4, 15, 9, 0, 0))
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)

    child = DAG::Workflow::Loader.from_hash(
      gated: {
        type: :ruby,
        schedule: {not_before: future_time},
        callable: ->(_input) { DAG::Success.new(value: "later") }
      }
    )

    parent = DAG::Workflow::Loader.from_hash(
      seed: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "seed") }
      },
      process: {
        type: :sub_workflow,
        definition: child,
        depends_on: [:seed]
      },
      sibling: {
        type: :ruby,
        depends_on: [:seed],
        callable: ->(input) { DAG::Success.new(value: "sibling:#{input[:seed]}") }
      },
      join: {
        type: :ruby,
        depends_on: [:process, :sibling],
        callable: ->(input) { DAG::Success.new(value: "joined") }
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false, clock: clock).call

    assert_equal :waiting, result.status
    assert_equal "seed", result.outputs[:seed].value
    assert_equal "sibling:seed", result.outputs[:sibling].value
    refute result.outputs.key?(:join)

    join_entry = result.trace.find { |e| e.name == :join }
    refute_nil join_entry
    assert_equal :blocked_upstream, join_entry.status
  end

  def test_lifecycle_paused_blocks_downstream_when_pause_flag_not_set_externally
    fake_paused = ->(_input) do
      DAG::Success.new(value: {
        __sub_workflow_status__: :paused,
        __sub_workflow_trace__: []
      })
    end

    parent = DAG::Workflow::Loader.from_hash(
      process: {
        type: :ruby,
        callable: fake_paused
      },
      finalize: {
        type: :ruby,
        depends_on: [:process],
        callable: ->(input) { DAG::Success.new(value: "finalized:#{input[:process]}") }
      }
    )

    result = DAG::Workflow::Runner.new(parent, parallel: false).call

    assert_equal :paused, result.status
    refute result.outputs.key?(:process)
    refute result.outputs.key?(:finalize)

    finalize_entry = result.trace.find { |e| e.name == :finalize }
    refute_nil finalize_entry, "expected blocked_upstream trace entry for :finalize"
    assert_equal :blocked_upstream, finalize_entry.status
  end

  private

  def parent_with_waiting_child_and(downstream:)
    future_time = Time.utc(2026, 4, 15, 10, 0, 0)

    child = DAG::Workflow::Loader.from_hash(
      gated: {
        type: :ruby,
        schedule: {not_before: future_time},
        callable: ->(_input) { DAG::Success.new(value: "later") }
      }
    )

    nodes = {process: {type: :sub_workflow, definition: child}}.merge(downstream)
    DAG::Workflow::Loader.from_hash(**nodes)
  end
end
