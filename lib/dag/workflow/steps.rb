# frozen_string_literal: true

require_relative "steps/exec"
require_relative "steps/ruby_script"
require_relative "steps/file_read"
require_relative "steps/file_write"
require_relative "steps/ruby"
require_relative "steps/sub_workflow"

module DAG
  module Workflow
    module Steps
      class << self
        def register(type, klass, yaml_safe: false)
          raise DAG::Error, "Step registry is frozen — register steps before calling freeze_registry!" if @frozen

          @registry[type.to_sym] = {klass: klass, yaml_safe: yaml_safe}
        end

        def build(type)
          class_for(type).new
        end

        # Returns the registered Class for `type` without instantiating it.
        # Used by the Runner so it can build a `Parallel::Task` carrying the
        # executor class without paying for a throwaway instance.
        def class_for(type)
          entry = @registry.fetch(type.to_sym) { raise ArgumentError, "Unknown step type: #{type}" }
          entry[:klass]
        end

        def registered?(type)
          @registry.key?(type.to_sym)
        end

        def types
          @registry.keys
        end

        def yaml_types
          @registry.select { |_, v| v[:yaml_safe] }.keys
        end

        def freeze_registry!
          @registry.each_value(&:freeze)
          @registry.freeze
          @frozen = true
        end
      end

      @registry = {}
      @frozen = false

      register(:exec, Exec, yaml_safe: true)
      register(:ruby_script, RubyScript, yaml_safe: true)
      register(:file_read, FileRead, yaml_safe: true)
      register(:file_write, FileWrite, yaml_safe: true)
      register(:ruby, Ruby, yaml_safe: false)
      register(:sub_workflow, SubWorkflow, yaml_safe: false)
    end
  end
end
