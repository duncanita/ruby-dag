# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class RubyScript
        DEFAULT_TIMEOUT = 60

        def call(step, _input)
          path = step.config[:path]
          unless path
            return Failure.new(error: {
              code: :ruby_script_no_path,
              message: "ruby_script step #{step.name} has no :path config"
            })
          end
          unless File.exist?(path)
            return Failure.new(error: {
              code: :ruby_script_not_found,
              message: "ruby_script step #{step.name}: script not found at #{path}",
              path: path
            })
          end

          argv = ["ruby", path, *Array(step.config[:args]).map(&:to_s)]
          Exec.run_command(argv, timeout: step.config.fetch(:timeout, DEFAULT_TIMEOUT))
        end
      end
    end
  end
end
