# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module DAG
      class NoExternalRequires < Base
        MSG = "Runtime requires in ruby-dag must stay within the Ruby standard library."
        STDLIB = %w[
          digest
          digest/sha2
          etc
          fileutils
          forwardable
          json
          logger
          pathname
          securerandom
          set
          singleton
          time
          yaml
        ].freeze
        RESTRICT_ON_SEND = %i[require].freeze

        def on_send(node)
          return unless runtime_file?

          feature = node.first_argument
          return unless feature&.str_type?
          return if STDLIB.include?(feature.value)

          add_offense(node)
        end

        private

        def runtime_file?
          path = processed_source.file_path
          path.include?("/lib/dag/") || path.end_with?("/lib/dag.rb")
        end
      end
    end
  end
end
