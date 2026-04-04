# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class LLM
        def call(node, input)
          prompt = node.config[:prompt]
          return Failure.new(error: "No prompt for LLM node #{node.name}") unless prompt

          command = node.config[:command]
          return Failure.new(error: "No command for LLM node #{node.name}. Provide a command that accepts the prompt.") unless command

          render_prompt(prompt, input)
            .then { |rendered| execute(rendered, command, node.config.fetch(:timeout, 120)) }
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
