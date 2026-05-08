# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module DAG
      class NoThreadOrRactor < Base
        MSG = "Do not use thread/ractor primitives or process spawning in ruby-dag kernel code."
        FORBIDDEN_CONS = %w[Thread Ractor Mutex Monitor Queue SizedQueue ConditionVariable].freeze
        DISPATCHER_RELAXED_CONS = %w[Thread Queue].freeze
        FORBIDDEN_THREAD_SENDS = %i[new start fork].freeze
        # The carve-out documented in Roadmap §2.4 / §9.1 is "Thread for the
        # worker pool", which structurally means `Thread.new`. `Thread.start`
        # and `Thread.fork` stay banned even in the dispatcher: bounded
        # parallel_map does not need them, and keeping them blocked closes
        # the gap between the documented exception and the cop allow-list.
        DISPATCHER_RELAXED_THREAD_SENDS = %i[new].freeze
        FORBIDDEN_PROCESS_SENDS = %i[fork spawn daemon].freeze

        def on_const(node)
          return unless FORBIDDEN_CONS.include?(node.const_name)
          return if dispatcher_relaxed_file? && DISPATCHER_RELAXED_CONS.include?(node.const_name)

          add_offense(node)
        end

        def on_send(node)
          receiver = node.receiver
          method_name = node.method_name

          if receiver&.const_type? && receiver.const_name == "Process"
            add_offense(node) if runtime_file? && FORBIDDEN_PROCESS_SENDS.include?(method_name)
            return
          end

          if receiver&.const_type? && %w[Thread Ractor].include?(receiver.const_name)
            if dispatcher_relaxed_file? && receiver.const_name == "Thread" &&
                DISPATCHER_RELAXED_THREAD_SENDS.include?(method_name)
              return
            end

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

        # Roadmap v3.4 §2.4 / §9.1 carve-out: the abstract effect dispatcher
        # is the single file allowed to use Thread + Queue for bounded
        # parallel dispatch from V1.3 onward. Mutex/Monitor/SizedQueue/
        # ConditionVariable/Ractor remain banned even in this file.
        def dispatcher_relaxed_file?
          processed_source.file_path.end_with?("/lib/dag/effects/dispatcher.rb")
        end
      end
    end
  end
end
