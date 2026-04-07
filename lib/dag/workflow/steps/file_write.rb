# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class FileWrite
        VALID_MODES = %w[w a].freeze

        def call(step, input)
          path = step.config[:path]
          return Failure.new(error: "No path for file_write step #{step.name}") unless path

          mode = step.config.fetch(:mode, "w")
          return Failure.new(error: "Invalid mode '#{mode}' for file_write step #{step.name}. Valid: #{VALID_MODES.join(", ")}") unless VALID_MODES.include?(mode)

          resolve_content(step, input).and_then do |content|
            File.open(path, mode) { |f| f.write(content) }
            Success.new(value: path)
          end
        rescue SystemCallError, IOError => e
          Failure.new(error: "Write error: #{e.message}")
        end

        private

        # Resolves what to write. Always returns a Result so the caller can
        # chain with `.and_then` without sniffing the return type — and so a
        # step whose upstream value is literally a `Failure` object does not
        # get mistaken for a resolver error. Precedence:
        #   1. explicit :content config
        #   2. explicit :from config -> input[from]
        #   3. single-dep input        -> the only value
        #   4. anything else           -> Failure (no silent Hash#to_s footgun)
        def resolve_content(step, input)
          return Success.new(value: step.config[:content]) if step.config.key?(:content)

          from = step.config[:from]
          if from
            from_sym = from.to_sym
            unless input.is_a?(Hash) && input.key?(from_sym)
              return Failure.new(error: "file_write step #{step.name}: :from refers to #{from_sym} but no such input present")
            end
            return Success.new(value: input[from_sym])
          end

          case input
          when Hash
            case input.size
            when 1 then Success.new(value: input.values.first)
            when 0 then Failure.new(error: "file_write step #{step.name} has no content: set :content, :from, or add an upstream dep")
            else Failure.new(error: "file_write step #{step.name} has multiple upstream deps (#{input.keys.sort.join(", ")}); specify :from or :content")
            end
          else
            Success.new(value: input)
          end
        end
      end
    end
  end
end
