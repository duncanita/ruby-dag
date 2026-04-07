# frozen_string_literal: true

require "shellwords"

module DAG
  module Workflow
    module Steps
      class RubyScript
        DEFAULT_TIMEOUT = 60

        def call(step, _input)
          path = step.config[:path]
          return Failure.new(error: "No path for ruby_script step #{step.name}") unless path
          return Failure.new(error: "Script not found: #{path}") unless File.exist?(path)

          command = Shellwords.join(["ruby", path, *Array(step.config[:args])])
          Exec.run_command(command, timeout: step.config.fetch(:timeout, DEFAULT_TIMEOUT))
        end
      end
    end
  end
end
