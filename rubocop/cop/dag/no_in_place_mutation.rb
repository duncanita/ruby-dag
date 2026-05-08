# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module DAG
      class NoInPlaceMutation < Base
        MSG = "Do not mutate pure kernel values in place."
        MUTATING_METHODS = %i[push << merge! update delete clear shift pop []=].freeze
        # Methods the V1.3 dispatcher carve-out lets through in
        # `lib/dag/effects/dispatcher.rb` because bounded `parallel_map`
        # needs queue feed (`<<`), worker drain (`pop`), and
        # slot-indexed result writes (`[]=`). Every other mutating method
        # stays banned even in the dispatcher.
        DISPATCHER_RELAXED_METHODS = %i[<< []= pop].freeze
        # Files that wrap their state in Data.define and must not mutate it
        # in place. Everything under `lib/dag/effects/` is also pure value
        # code. `immutability.rb` is intentionally NOT in this list — it is
        # the implementation of `deep_dup` / `deep_freeze` / `json_safe!` and
        # necessarily mutates the local hashes it is constructing.
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
          return unless pure_kernel_file?
          return if dispatcher_relaxed_file? && DISPATCHER_RELAXED_METHODS.include?(node.method_name)

          add_offense(node)
        end

        private

        def pure_kernel_file?
          path = processed_source.file_path
          PURE_KERNEL_FILES.any? { |file| path.end_with?("/lib/dag/#{file}") } ||
            path.include?("/lib/dag/effects/") ||
            path.include?("/lib/dag/ports/")
        end

        # Roadmap v3.4 §2.4 / §9.1 V1.3 carve-out: the abstract effect
        # dispatcher can use `<<` (queue feed), `pop` (worker drain), and
        # `[]=` (slot-indexed result writes) for bounded `parallel_map`.
        # Other mutating methods (`merge!`, `update`, `delete`, `clear`,
        # `shift`, `push`) stay banned even in this file.
        def dispatcher_relaxed_file?
          processed_source.file_path.end_with?("/lib/dag/effects/dispatcher.rb")
        end
      end
    end
  end
end
