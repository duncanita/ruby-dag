# frozen_string_literal: true

require "open3"
require "timeout"

module DAG
  module Steps
    class LLM
      def call(node, input)
        prompt = node.config[:prompt]
        return Failure.new(error: "No prompt for LLM node #{node.name}") unless prompt

        command = node.config[:command]
        return Failure.new(error: "No command for LLM node #{node.name}. Provide a command that accepts the prompt.") unless command

        render_prompt(prompt, input)
          .then { |rendered| execute(node, rendered, command) }
      end

      private

      def render_prompt(prompt, input)
        prompt.gsub("{{input}}", input.to_s)
      end

      def execute(node, rendered, command)
        env = { "DAG_LLM_PROMPT" => rendered }
        timeout = node.config.fetch(:timeout, 120)

        Timeout.timeout(timeout) { Open3.capture3(env, command) }
          .then { |stdout, stderr, status| build_result(stdout, stderr, status) }
      rescue Timeout::Error
        Failure.new(error: "LLM command timed out after #{timeout}s")
      end

      def build_result(stdout, stderr, status)
        if status.success?
          Success.new(value: stdout.strip)
        else
          Failure.new(error: "LLM exit #{status.exitstatus}: #{stderr.strip}")
        end
      end
    end
  end
end
