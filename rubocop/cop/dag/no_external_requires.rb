# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module DAG
      class NoExternalRequires < Base
        MSG = "Runtime requires in ruby-dag must stay within the Ruby standard library."
        # The frozen-decision stdlib allowlist from Roadmap v3.4 §3.
        # Anything else (including other stdlib gems such as etc, singleton,
        # or yaml) needs a documented contract extension first.
        STDLIB = %w[
          digest
          fileutils
          forwardable
          json
          logger
          pathname
          securerandom
          set
          time
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
