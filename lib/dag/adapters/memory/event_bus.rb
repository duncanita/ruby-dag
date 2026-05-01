# frozen_string_literal: true

module DAG
  module Adapters
    module Memory
      # In-memory event bus. Single-process, single-thread. Bounded ring
      # buffer — once full, oldest events are dropped. Events read out are
      # always deep-frozen deep-dups; the internal buffer is never exposed.
      # @api public
      class EventBus
        include Ports::EventBus

        # Default ring-buffer capacity.
        DEFAULT_BUFFER_SIZE = 1000

        # @param buffer_size [Integer] ring-buffer capacity
        def initialize(buffer_size: DEFAULT_BUFFER_SIZE)
          @buffer_size = buffer_size
          @events = []
          @subscribers = []
        end

        # @param event [DAG::Event]
        # @return [nil]
        def publish(event)
          frozen_event = DAG.frozen_copy(event)
          @events << frozen_event
          @events.shift if @events.size > @buffer_size
          @subscribers.dup.each { |subscriber| subscriber.call(frozen_event) }
          nil
        end

        # @yieldparam event [DAG::Event]
        # @return [Proc] unsubscribe callable
        # @raise [ArgumentError] when no block is supplied
        def subscribe(&block)
          raise ArgumentError, "block required" unless block

          @subscribers << block
          -> { @subscribers.delete(block) }
        end

        # @return [Array<DAG::Event>] deep-frozen copy of the buffer
        def events
          DAG.frozen_copy(@events)
        end
      end
    end
  end
end
