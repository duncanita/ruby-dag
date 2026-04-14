# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      # Writes content to the file at `step.config[:path]`. No path
      # sandboxing is applied — the caller is responsible for validating
      # paths if workflow definitions come from untrusted sources.
      class FileWrite
        VALID_MODES = %w[w a].freeze

        def call(step, input)
          path = step.config[:path]
          unless path
            return Failure.new(error: {
              code: :file_write_no_path,
              message: "file_write step #{step.name} has no :path config"
            })
          end

          mode = step.config.fetch(:mode, "w")
          unless VALID_MODES.include?(mode)
            return Failure.new(error: {
              code: :file_write_invalid_mode,
              message: "file_write step #{step.name}: invalid mode '#{mode}' (valid: #{VALID_MODES.join(", ")})",
              mode: mode,
              valid_modes: VALID_MODES
            })
          end

          resolve_content(step, input).and_then do |content|
            File.open(path, mode) { |f| f.write(content) }
            Success.new(value: path)
          end
        rescue SystemCallError, IOError => e
          Result.exception_failure(:file_write_io_error, e,
            message: "file_write step #{step.name}: #{e.message}",
            path: path)
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
              return Failure.new(error: {
                code: :file_write_missing_from_input,
                message: "file_write step #{step.name}: :from refers to #{from_sym} but no such input present",
                from: from_sym
              })
            end
            return Success.new(value: input[from_sym])
          end

          case input
          when Hash
            case input.size
            when 1 then Success.new(value: input.values.first)
            when 0
              Failure.new(error: {
                code: :file_write_no_content,
                message: "file_write step #{step.name} has no content: set :content, :from, or add an upstream dep"
              })
            else
              Failure.new(error: {
                code: :file_write_ambiguous_input,
                message: "file_write step #{step.name} has multiple upstream deps (#{input.keys.sort.join(", ")}); specify :from or :content",
                input_keys: input.keys.sort
              })
            end
          else
            Success.new(value: input)
          end
        end
      end
    end
  end
end
