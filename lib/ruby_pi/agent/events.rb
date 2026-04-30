# frozen_string_literal: true

# lib/ruby_pi/agent/events.rb
#
# Defines the canonical set of agent lifecycle event types and the EventEmitter
# mixin that provides publish/subscribe functionality. Any class that includes
# EventEmitter gains the ability to register event handlers with `on`, fire them
# with `emit`, and remove them with `off`. The Agent::Core class uses this to
# broadcast progress events (text deltas, tool execution, errors) to subscribers.

module RubyPi
  module Agent
    # Canonical event types emitted during the agent lifecycle. Each symbol
    # represents a specific moment or occurrence:
    #
    # - :text_delta           — An incremental text chunk from the LLM stream.
    # - :tool_call_delta      — An incremental tool call chunk from the LLM stream.
    # - :tool_execution_start — A tool is about to be executed.
    # - :tool_execution_end   — A tool has finished executing.
    # - :turn_start           — A new think-act-observe cycle is beginning.
    # - :turn_end             — A think-act-observe cycle has completed.
    # - :agent_end            — The agent has finished its run (final event).
    # - :error                — A recoverable or fatal error occurred.
    # - :compaction           — Context compaction was triggered.
    EVENTS = %i[
      text_delta
      tool_call_delta
      tool_execution_start
      tool_execution_end
      turn_start
      turn_end
      agent_end
      error
      compaction
    ].freeze

    # Mixin that adds event subscription and emission to any class. Include
    # this module and call `on`, `emit`, and `off` to wire up event-driven
    # communication between components.
    #
    # @example Using EventEmitter in a class
    #   class MyService
    #     include RubyPi::Agent::EventEmitter
    #   end
    #
    #   svc = MyService.new
    #   svc.on(:text_delta) { |data| puts data[:content] }
    #   svc.emit(:text_delta, content: "Hello")
    module EventEmitter
      # Subscribes a handler block to a specific event type. The block will
      # be called every time `emit` fires for that event. Multiple handlers
      # can be registered for the same event — they are invoked in the order
      # they were registered.
      #
      # @param event [Symbol] the event type to subscribe to (must be in EVENTS)
      # @param block [Proc] the handler to invoke when the event fires
      # @return [Proc] the registered handler block, for later removal via `off`
      # @raise [ArgumentError] if the event type is not in EVENTS
      def on(event, &block)
        validate_event!(event)
        event_handlers[event] << block
        block
      end

      # Fires all handlers registered for the given event type. Each handler
      # receives the `data` hash as its argument. Handlers that raise are
      # rescued individually — one failing handler does not prevent others
      # from executing.
      #
      # If a handler raises during a non-error event, the error is re-emitted
      # as an :error event so subscribers can observe it. To prevent infinite
      # recursion, errors raised inside :error event handlers are silently
      # swallowed — they are not re-emitted. This ensures that a broken error
      # handler cannot crash the agent loop.
      #
      # @param event [Symbol] the event type to fire
      # @param data [Hash] arbitrary payload passed to each handler
      # @return [void]
      def emit(event, data = {})
        validate_event!(event)
        event_handlers[event].each do |handler|
          handler.call(data)
        rescue StandardError => e
          # Guard against infinite recursion: if we are already emitting an
          # :error event and the error handler itself raises, we must not
          # re-emit — that would cause unbounded recursion. Silently discard
          # the secondary error instead.
          if event != :error
            emit(:error, error: e, source: :event_handler, event: event)
          end
        end
      end

      # Removes a specific handler from an event's subscriber list. If the
      # handler is not found, this is a no-op. Pass the same block reference
      # that was given to `on`.
      #
      # @param event [Symbol] the event type to unsubscribe from
      # @param block [Proc] the handler to remove
      # @return [Proc, nil] the removed handler, or nil if not found
      def off(event, &block)
        validate_event!(event)
        event_handlers[event].delete(block)
      end

      private

      # Returns (and lazily initializes) the internal handler registry.
      # Each event type maps to an array of callable handler blocks.
      #
      # @return [Hash{Symbol => Array<Proc>}] handlers keyed by event type
      def event_handlers
        @event_handlers ||= Hash.new { |h, k| h[k] = [] }
      end

      # Validates that the given event symbol is a recognized event type.
      #
      # @param event [Symbol] the event type to validate
      # @raise [ArgumentError] if the event is not in EVENTS
      def validate_event!(event)
        return if EVENTS.include?(event)

        raise ArgumentError,
              "Unknown event type: #{event.inspect}. " \
              "Must be one of: #{EVENTS.join(', ')}"
      end
    end
  end
end
