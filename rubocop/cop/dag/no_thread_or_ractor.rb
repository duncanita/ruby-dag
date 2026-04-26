# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module DAG
      class NoThreadOrRactor < Base
        MSG = "Do not use thread/ractor primitives or process spawning in ruby-dag kernel code."
        FORBIDDEN_CONS = %w[Thread Ractor Mutex Monitor Queue SizedQueue ConditionVariable].freeze
        FORBIDDEN_THREAD_SENDS = %i[new start fork].freeze
        FORBIDDEN_PROCESS_SENDS = %i[fork spawn daemon].freeze

        def on_const(node)
          add_offense(node) if FORBIDDEN_CONS.include?(node.const_name)
        end

        def on_send(node)
          receiver = node.receiver
          method_name = node.method_name

          if receiver&.const_type? && receiver.const_name == "Process"
            add_offense(node) if runtime_file? && FORBIDDEN_PROCESS_SENDS.include?(method_name)
            return
          end

          if receiver&.const_type? && %w[Thread Ractor].include?(receiver.const_name)
            add_offense(node) if FORBIDDEN_THREAD_SENDS.include?(method_name)
            return
          end

          add_offense(node) if runtime_file? && method_name == :system && receiver.nil?
        end

        def on_xstr(node)
          add_offense(node) if runtime_file?
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
