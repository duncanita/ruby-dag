# frozen_string_literal: true

require "open3"
require "timeout"
require "shellwords"

module DAG
  module Steps
    # Execute a shell command. Returns stdout as value.
    class Exec
      def call(node, _input)
        command = node.config[:command]
        return Failure.new(error: "No command for exec node #{node.name}") unless command

        run_command(command, node.config.fetch(:timeout, 30))
      end

      private

      def run_command(command, timeout)
        Timeout.timeout(timeout) { Open3.capture3(command) }
          .then { |stdout, stderr, status| build_result(stdout, stderr, status) }
      rescue Timeout::Error
        Failure.new(error: "Command timed out after #{timeout}s")
      end

      def build_result(stdout, stderr, status)
        if status.success?
          Success.new(value: stdout.strip)
        else
          Failure.new(error: "Exit #{status.exitstatus}: #{stderr.strip}")
        end
      end
    end

    # Run a Ruby script file. Returns stdout as value.
    class Script
      def call(node, _input)
        path = node.config[:path]
        return Failure.new(error: "Script not found: #{path}") unless path && File.exist?(path)

        build_command(path, node.config)
          .then { |cmd, timeout| Exec.new.call(Node.new(name: node.name, type: :exec, command: cmd, timeout: timeout), nil) }
      end

      private

      def build_command(path, config)
        args = Array(config[:args]).map { |a| Shellwords.shellescape(a) }.join(" ")
        timeout = config.fetch(:timeout, 60)
        cmd = args.empty? ? "ruby #{Shellwords.shellescape(path)}" : "ruby #{Shellwords.shellescape(path)} #{args}"
        [cmd, timeout]
      end
    end

    # Read a file. Returns content as value.
    class FileRead
      def call(node, _input)
        path = node.config[:path]
        return Failure.new(error: "No path for file_read node #{node.name}") unless path
        return Failure.new(error: "File not found: #{path}") unless File.exist?(path)

        Success.new(value: File.read(path))
      rescue => e
        Failure.new(error: "Read error: #{e.message}")
      end
    end

    # Write content to a file. Content from config or input.
    class FileWrite
      def call(node, input)
        path = node.config[:path]
        return Failure.new(error: "No path for file_write node #{node.name}") unless path

        content = node.config[:content] || input
        mode = node.config.fetch(:mode, "w")

        File.open(path, mode) { |f| f.write(content) }
        Success.new(value: path)
      rescue => e
        Failure.new(error: "Write error: #{e.message}")
      end
    end

    # Evaluate a Ruby callable. Must return a Result.
    class Ruby
      def call(node, input)
        callable = node.config[:callable]
        return Failure.new(error: "No callable for ruby node #{node.name}") unless callable

        callable.call(input)
      rescue => e
        Failure.new(error: "Ruby error: #{e.class}: #{e.message}")
      end
    end

    # LLM call — renders a prompt template and executes via a command.
    # Requires an explicit :command in config. No unsafe defaults.
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
        # Pass rendered prompt via env var to avoid shell injection
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

    def self.build(type)
      case type.to_sym
      when :exec       then Exec.new
      when :script     then Script.new
      when :file_read  then FileRead.new
      when :file_write then FileWrite.new
      when :ruby       then Ruby.new
      when :llm        then LLM.new
      else raise ArgumentError, "Unknown step type: #{type}"
      end
    end
  end
end
