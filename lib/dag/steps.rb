# frozen_string_literal: true

module DAG
  module Steps
    # Execute a shell command. Returns stdout as value.
    class Exec
      def call(node, input)
        command = node.config[:command]
        timeout = node.config.fetch(:timeout, 30)

        stdout, stderr, status = nil
        begin
          Timeout.timeout(timeout) do
            stdout, stderr, status = Open3.capture3(command)
          end
        rescue Timeout::Error
          return Result.failure("Command timed out after #{timeout}s: #{command}")
        end

        if status.success?
          Result.success(stdout.strip)
        else
          Result.failure("Exit #{status.exitstatus}: #{stderr.strip}")
        end
      end
    end

    # Run a Ruby script file. Returns stdout as value.
    class Script
      def call(node, input)
        path = node.config[:path]
        return Result.failure("Script not found: #{path}") unless File.exist?(path)

        args = node.config.fetch(:args, "")
        timeout = node.config.fetch(:timeout, 60)

        Exec.new.call(
          Node.new(name: node.name, type: :exec, command: "ruby #{path} #{args}", timeout: timeout),
          input
        )
      end
    end

    # Read a file. Returns content as value.
    class FileRead
      def call(node, input)
        path = node.config[:path]
        return Result.failure("File not found: #{path}") unless File.exist?(path)

        Result.success(File.read(path))
      rescue => e
        Result.failure("Read error: #{e.message}")
      end
    end

    # Write content to a file. Content comes from input or config.
    class FileWrite
      def call(node, input)
        path = node.config[:path]
        content = node.config[:content] || input
        mode = node.config.fetch(:mode, "w") # "w" = overwrite, "a" = append

        File.open(path, mode) { |f| f.write(content) }
        Result.success(path)
      rescue => e
        Result.failure("Write error: #{e.message}")
      end
    end

    # Evaluate a Ruby block/proc. The block receives input and must return a Result.
    class Ruby
      def call(node, input)
        callable = node.config[:callable]
        return Result.failure("No callable provided for ruby node #{node.name}") unless callable

        callable.call(input)
      rescue => e
        Result.failure("Ruby error: #{e.class}: #{e.message}")
      end
    end

    # Placeholder for LLM calls — extensible.
    class LLM
      def call(node, input)
        prompt = node.config[:prompt]
        return Result.failure("No prompt provided for LLM node #{node.name}") unless prompt

        # Interpolate input into prompt
        rendered = prompt.gsub("{{input}}", input.to_s)

        # For now, shell out to a command. Can be replaced with API calls.
        command = node.config[:command] || "echo '#{rendered}'"
        timeout = node.config.fetch(:timeout, 120)

        Exec.new.call(
          Node.new(name: node.name, type: :exec, command: command, timeout: timeout),
          input
        )
      end
    end

    REGISTRY = {
      exec: Exec.new,
      script: Script.new,
      file_read: FileRead.new,
      file_write: FileWrite.new,
      ruby: Ruby.new,
      llm: LLM.new
    }.freeze

    def self.for(type)
      REGISTRY.fetch(type) { raise ArgumentError, "Unknown step type: #{type}" }
    end
  end
end
