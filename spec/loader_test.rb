# frozen_string_literal: true

require_relative "test_helper"

class LoaderTest < Minitest::Test
  def test_loads_simple_workflow
    defn = load_yaml(<<~YAML)
      name: test
      nodes:
        greet:
          type: exec
          command: "echo hello"
    YAML

    assert_equal 1, defn.size
    assert_equal :exec, defn.step(:greet).type
  end

  def test_loads_dependencies
    defn = load_yaml(<<~YAML)
      name: test
      nodes:
        first:
          type: exec
          command: "echo 1"
        second:
          type: exec
          command: "echo 2"
          depends_on:
            - first
    YAML

    assert_equal [[:first], [:second]], defn.execution_order
  end

  def test_loads_all_core_node_types
    defn = load_yaml(<<~YAML)
      name: test
      nodes:
        a:
          type: exec
          command: "echo a"
        b:
          type: file_read
          path: "/tmp/test.txt"
        c:
          type: file_write
          path: "/tmp/out.txt"
          depends_on: [b]
    YAML

    assert_equal 3, defn.size
  end

  def test_passes_extra_config_through
    defn = load_yaml(<<~YAML)
      name: test
      nodes:
        task:
          type: exec
          command: "echo x"
          timeout: 60
          custom_key: "custom_value"
    YAML

    assert_equal 60, defn.step(:task).config[:timeout]
    assert_equal "custom_value", defn.step(:task).config[:custom_key]
  end

  def test_symbolizes_schedule_metadata_keys_from_yaml
    defn = load_yaml(<<~YAML)
      nodes:
        task:
          type: exec
          command: "echo x"
          schedule:
            not_before: "2026-04-15T09:00:00Z"
            not_after: "2026-04-15T10:00:00Z"
            ttl: 3600
            cron: "0 * * * *"
    YAML

    assert_equal({
      not_before: "2026-04-15T09:00:00Z",
      not_after: "2026-04-15T10:00:00Z",
      ttl: 3600,
      cron: "0 * * * *"
    }, defn.step(:task).config[:schedule])
  end

  def test_rejects_non_hash_schedule_config
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          task:
            type: exec
            command: "echo x"
            schedule: later
      YAML
    end

    assert_match(/schedule must be a mapping/, error.message)
  end

  def test_loads_declarative_run_if_from_yaml
    defn = load_yaml(<<~YAML)
      nodes:
        decide:
          type: exec
          command: "echo prod"
        deploy:
          type: exec
          command: "echo deploy"
          depends_on: [decide]
          run_if:
            from: decide
            value:
              equals: "prod"
    YAML

    assert_equal({from: :decide, value: {equals: "prod"}}, defn.step(:deploy).config[:run_if])
  end

  def test_loads_from_file
    file = Tempfile.new(["workflow", ".yml"])
    file.write(<<~YAML)
      name: file-test
      nodes:
        only:
          type: exec
          command: "echo from-file"
    YAML
    file.close

    defn = DAG::Workflow::Loader.from_file(file.path)
    assert_equal 1, defn.size
  ensure
    file&.unlink
  end

  # --- Error handling ---
  #
  # Structural problems with the workflow definition surface as
  # DAG::ValidationError (< DAG::Error). Infrastructure problems like a
  # missing YAML file stay as ArgumentError — they are not a statement
  # about the workflow content.

  def test_rejects_missing_nodes_key
    assert_raises(DAG::ValidationError) { load_yaml("name: test") }
  end

  def test_rejects_non_hash_yaml_root
    # Bare list at the root used to crash with NoMethodError on Array#key?
    error = assert_raises(DAG::ValidationError) { load_yaml("- a\n- b\n") }
    assert_match(/mapping/, error.message)
  end

  def test_rejects_non_hash_nodes_value
    # `nodes:` with a list value used to crash deep inside normalize_entries.
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          - foo
          - bar
      YAML
    end
    assert_match(/mapping/, error.message)
  end

  def test_rejects_missing_type
    assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        name: test
        nodes:
          bad:
            command: "echo oops"
      YAML
    end
  end

  def test_rejects_explicit_nil_type
    # `type: ~` used to crash with NoMethodError on `nil.to_sym`. Now it
    # raises ValidationError like any other missing type.
    assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          bad:
            type: ~
            command: "echo oops"
      YAML
    end
  end

  def test_rejects_invalid_type
    assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        name: test
        nodes:
          bad:
            type: banana
            command: "echo oops"
      YAML
    end
  end

  def test_detects_cycle_in_yaml
    assert_raises(DAG::CycleError) do
      load_yaml(<<~YAML)
        name: test
        nodes:
          a:
            type: exec
            command: "echo a"
            depends_on: [b]
          b:
            type: exec
            command: "echo b"
            depends_on: [a]
      YAML
    end
  end

  def test_rejects_missing_file
    assert_raises(ArgumentError) { DAG::Workflow::Loader.from_file("/nonexistent.yml") }
  end

  def test_rejects_unknown_dependency
    assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        name: test
        nodes:
          a:
            type: exec
            command: "echo a"
            depends_on: [missing]
      YAML
    end
  end

  def test_rejects_blank_run_if
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          a:
            type: exec
            command: "echo ok"
          b:
            type: exec
            command: "echo deploy"
            depends_on: [a]
            run_if:
      YAML
    end

    assert_match(/blank run_if/, error.message)
  end

  def test_rejects_run_if_that_is_not_a_mapping
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          decide:
            type: exec
            command: "echo prod"
          deploy:
            type: exec
            command: "echo deploy"
            depends_on: [decide]
            run_if: true
      YAML
    end

    assert_match(/run_if/, error.message)
    assert_match(/mapping/, error.message)
  end

  def test_rejects_run_if_with_empty_all
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          decide:
            type: exec
            command: "echo prod"
          deploy:
            type: exec
            command: "echo deploy"
            depends_on: [decide]
            run_if:
              all: []
      YAML
    end

    assert_match(/non-empty array/, error.message)
  end

  def test_rejects_run_if_with_unknown_value_predicate
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          decide:
            type: exec
            command: "echo prod"
          deploy:
            type: exec
            command: "echo deploy"
            depends_on: [decide]
            run_if:
              from: decide
              value:
                greater_than: 1
      YAML
    end

    assert_match(/equals, in, present, nil, matches/, error.message)
  end

  def test_rejects_run_if_referencing_non_dependency
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          decide:
            type: exec
            command: "echo prod"
          audit:
            type: exec
            command: "echo audit"
          deploy:
            type: exec
            command: "echo deploy"
            depends_on: [decide]
            run_if:
              from: audit
              status: success
      YAML
    end

    assert_match(/direct dependencies/, error.message)
    assert_match(/audit/, error.message)
  end

  # --- malformed node definitions ---

  def test_rejects_nil_node_definition
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          bad: ~
      YAML
    end
    assert_match(/must be a mapping/, error.message)
    assert_match(/bad/, error.message)
  end

  def test_rejects_numeric_node_definition
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          bad: 42
      YAML
    end
    assert_match(/must be a mapping/, error.message)
  end

  def test_rejects_string_node_definition
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          bad: "just a string"
      YAML
    end
    assert_match(/must be a mapping/, error.message)
  end

  def test_loads_cross_workflow_dependency_descriptor
    defn = load_yaml(<<~YAML)
      nodes:
        fetch:
          type: exec
          command: "echo a"
        consume:
          type: exec
          command: "echo b"
          depends_on:
            - fetch
            - workflow: pipeline-a
              node: validated_output
              version: latest
              as: validated
    YAML

    assert_equal [[:fetch], [:consume]], defn.execution_order
    assert_equal [{workflow_id: "pipeline-a", node: :validated_output, version: :latest, as: :validated}],
      defn.step(:consume).config[:external_dependencies]
  end

  def test_rejects_depends_on_hash_missing_source_descriptor
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          a:
            type: exec
            command: "echo a"
          b:
            type: exec
            command: "echo b"
            depends_on:
              - weight: 3
      YAML
    end
    assert_match(/either 'from' or both 'workflow' and 'node'/, error.message)
  end

  def test_rejects_depends_on_hash_mixing_local_and_cross_workflow_keys
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          a:
            type: exec
            command: "echo a"
          b:
            type: exec
            command: "echo b"
            depends_on:
              - from: a
                workflow: pipeline-a
                node: external
      YAML
    end
    assert_match(/cannot mix 'from' with cross-workflow keys/, error.message)
  end

  def test_from_hash_rejects_nil_node_definition
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(bad: nil)
    end
    assert_match(/must be a mapping/, error.message)
  end

  def test_from_hash_rejects_depends_on_hash_missing_source_descriptor
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        a: {type: :exec, command: "echo a"},
        b: {type: :exec, command: "echo b", depends_on: [{weight: 3}]}
      )
    end
    assert_match(/either 'from' or both 'workflow' and 'node'/, error.message)
  end

  def test_rejects_non_symbolizable_node_name
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          1:
            type: exec
            command: "echo hi"
      YAML
    end
    assert_match(/Node name must be symbolizable/, error.message)
  end

  def test_rejects_non_symbolizable_config_key
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          a:
            type: exec
            1: foo
      YAML
    end
    assert_match(/config key/, error.message)
    assert_match(/symbolizable/, error.message)
  end

  def test_rejects_non_symbolizable_depends_on_key
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          a:
            type: exec
            command: "echo a"
          b:
            type: exec
            command: "echo b"
            depends_on:
              - 1: a
      YAML
    end
    assert_match(/depends_on key/, error.message)
  end

  def test_rejects_non_symbolizable_depends_on_from
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        nodes:
          a:
            type: exec
            command: "echo a"
          b:
            type: exec
            command: "echo b"
            depends_on:
              - from: 1
      YAML
    end
    assert_match(/depends_on :from/, error.message)
  end

  def test_from_hash_rejects_non_symbolizable_node_name
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.send(:normalize_entries, {1 => {type: :exec, command: "echo nope"}}, string_keys: false)
    end
    assert_match(/Node name must be symbolizable/, error.message)
  end

  def test_from_hash_rejects_non_symbolizable_config_key
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.send(:normalize_entries,
        {a: {:type => :exec, :command => "echo ok", 1 => "bad key"}}, string_keys: false)
    end
    assert_match(/config key/, error.message)
  end

  def test_from_hash_rejects_non_symbolizable_depends_on_key
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        a: {type: :exec, command: "echo a"},
        b: {type: :exec, command: "echo b", depends_on: [{1 => :a}]}
      )
    end
    assert_match(/depends_on key/, error.message)
  end

  def test_from_hash_rejects_invalid_depends_on_entry
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        a: {type: :exec, command: "echo a"},
        b: {type: :exec, command: "echo b", depends_on: [42]}
      )
    end
    assert_match(/Invalid depends_on entry/, error.message)
  end

  def test_from_hash_rejects_non_symbolizable_depends_on_from
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        a: {type: :exec, command: "echo a"},
        b: {type: :exec, command: "echo b", depends_on: [{from: 1}]}
      )
    end
    assert_match(/depends_on :from/, error.message)
  end

  # --- ruby type rejection in YAML ---

  def test_rejects_ruby_type_in_yaml
    error = assert_raises(DAG::ValidationError) do
      load_yaml(<<~YAML)
        name: test
        nodes:
          bad:
            type: ruby
      YAML
    end
    assert_match(/not supported in YAML/, error.message)
  end

  # --- from_hash ---

  def test_from_hash_builds_workflow
    defn = DAG::Workflow::Loader.from_hash(
      greet: {type: :exec, command: "echo hello"}
    )

    assert_equal 1, defn.size
    assert_equal :exec, defn.step(:greet).type
    assert_equal "echo hello", defn.step(:greet).config[:command]
  end

  def test_from_hash_with_dependencies
    defn = DAG::Workflow::Loader.from_hash(
      first: {type: :exec, command: "echo 1"},
      second: {type: :exec, command: "echo 2", depends_on: [:first]}
    )

    assert_equal [[:first], [:second]], defn.execution_order
  end

  def test_from_hash_rejects_missing_type
    assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(bad: {command: "echo oops"})
    end
  end

  def test_from_hash_rejects_invalid_type
    assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(bad: {type: :banana})
    end
  end

  def test_from_hash_rejects_unknown_dependency
    assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        a: {type: :exec, command: "echo a", depends_on: [:missing]}
      )
    end
  end

  def test_from_hash_detects_cycle
    assert_raises(DAG::CycleError) do
      DAG::Workflow::Loader.from_hash(
        a: {type: :exec, command: "echo a", depends_on: [:b]},
        b: {type: :exec, command: "echo b", depends_on: [:a]}
      )
    end
  end

  def test_from_hash_accepts_ruby_type
    defn = DAG::Workflow::Loader.from_hash(
      task: {type: :ruby, callable: ->(_) { DAG::Success.new(value: "ok") }}
    )
    assert_equal :ruby, defn.step(:task).type
  end

  def test_from_hash_normalizes_declarative_run_if
    defn = DAG::Workflow::Loader.from_hash(
      decide: {type: :exec, command: "echo prod"},
      deploy: {type: :exec, command: "echo deploy", depends_on: [:decide],
               run_if: {"all" => [
                 {"from" => "decide", "status" => "success"},
                 {"not" => {"from" => "decide", "value" => {"nil" => true}}}
               ]}}
    )

    assert_equal(
      {all: [{from: :decide, status: :success}, {not: {from: :decide, value: {nil: true}}}]},
      defn.step(:deploy).config[:run_if]
    )
  end

  def test_from_hash_treats_nil_run_if_as_omitted
    defn = DAG::Workflow::Loader.from_hash(
      deploy: {type: :exec, command: "echo deploy", run_if: nil}
    )

    refute defn.step(:deploy).config.key?(:run_if)
  end

  def test_from_hash_rejects_malformed_declarative_run_if_at_construction
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        deploy: {type: :exec, command: "echo deploy", run_if: "bad"}
      )
    end

    assert_match(/run_if/, error.message)
    assert_match(/mapping/, error.message)
  end

  def test_from_hash_preserves_extra_config
    defn = DAG::Workflow::Loader.from_hash(
      task: {type: :exec, command: "echo x", timeout: 60, custom_key: "custom_value"}
    )

    assert_equal 60, defn.step(:task).config[:timeout]
    assert_equal "custom_value", defn.step(:task).config[:custom_key]
  end

  private

  def load_yaml(yaml) = DAG::Workflow::Loader.from_yaml(yaml)
end
