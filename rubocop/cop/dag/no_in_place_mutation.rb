# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module DAG
      class NoInPlaceMutation < Base
        MSG = "Do not mutate pure kernel values in place."
        MUTATING_METHODS = %i[push << merge! update delete clear shift pop []=].freeze
        # Files that wrap their state in Data.define and must not mutate it
        # in place. `immutability.rb` is intentionally NOT in this list — it
        # is the implementation of `deep_dup` / `deep_freeze` / `json_safe!`
        # and necessarily mutates the local hashes it is constructing.
        PURE_KERNEL_FILES = %w[
          event.rb
          proposed_mutation.rb
          replacement_graph.rb
          run_result.rb
          runtime_profile.rb
          step_input.rb
          types.rb
          waiting.rb
        ].freeze
        RESTRICT_ON_SEND = MUTATING_METHODS

        def on_send(node)
          add_offense(node) if pure_kernel_file?
        end

        private

        def pure_kernel_file?
          path = processed_source.file_path
          PURE_KERNEL_FILES.any? { |file| path.end_with?("/lib/dag/#{file}") } ||
            path.include?("/lib/dag/ports/")
        end
      end
    end
  end
end
