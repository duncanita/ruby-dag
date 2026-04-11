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

  def test_rejects_depends_on_hash_missing_from
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
    assert_match(/missing.*from/, error.message)
  end

  def test_from_hash_rejects_nil_node_definition
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(bad: nil)
    end
    assert_match(/must be a mapping/, error.message)
  end

  def test_from_hash_rejects_depends_on_hash_missing_from
    error = assert_raises(DAG::ValidationError) do
      DAG::Workflow::Loader.from_hash(
        a: {type: :exec, command: "echo a"},
        b: {type: :exec, command: "echo b", depends_on: [{weight: 3}]}
      )
    end
    assert_match(/missing.*from/, error.message)
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
