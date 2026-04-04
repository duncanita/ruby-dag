# frozen_string_literal: true

require_relative "steps/exec"
require_relative "steps/script"
require_relative "steps/file_read"
require_relative "steps/file_write"
require_relative "steps/ruby"
require_relative "steps/llm"

module DAG
  module Workflow
    module Steps
      REGISTRY = {
        exec: Exec,
        script: Script,
        file_read: FileRead,
        file_write: FileWrite,
        ruby: Ruby,
        llm: LLM
      }.freeze

      def self.build(type)
        REGISTRY.fetch(type.to_sym) { raise ArgumentError, "Unknown step type: #{type}" }.new
      end
    end
  end
end
