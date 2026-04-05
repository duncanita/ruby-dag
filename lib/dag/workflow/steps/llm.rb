# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class LLM
        def call(step, input)
          prompt = step.config[:prompt]
          return Failure.new(error: "No prompt for LLM step #{step.name}") unless prompt

          command = step.config[:command]
          return Failure.new(error: "No command for LLM step #{step.name}. Provide a command that accepts the prompt.") unless command

          render_prompt(prompt, input)
            .then { |rendered| execute(rendered, command, step.config.fetch(:timeout, 120)) }
        end

        private

        def render_prompt(prompt, input)
          prompt.gsub("{{input}}", input.to_s)
        end

        def execute(rendered, command, timeout)
          env = {"DAG_LLM_PROMPT" => rendered}
          Exec.new.run_with_env(command, env, timeout)
        end
      end
    end
  end
end
