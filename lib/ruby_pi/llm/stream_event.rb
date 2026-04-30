# frozen_string_literal: true

# lib/ruby_pi/llm/stream_event.rb
#
# Represents a single event in a streaming LLM response. When streaming is
# enabled, the provider yields a sequence of StreamEvent objects to the caller's
# block, allowing incremental processing of text deltas and tool call fragments.

module RubyPi
  module LLM
    # An event yielded during a streaming completion. Events carry a type
    # indicating what kind of data they contain and a data payload with
    # the actual content.
    #
    # @example Processing streaming events
    #   provider.complete(messages: msgs, stream: true) do |event|
    #     case event.type
    #     when :text_delta
    #       print event.data
    #     when :tool_call_delta
    #       accumulate_tool_call(event.data)
    #     when :done
    #       puts "\nStream complete"
    #     end
    #   end
    class StreamEvent
      # Valid event types for stream events.
      VALID_TYPES = %i[text_delta tool_call_delta done fallback_start].freeze

      # @return [Symbol] the type of stream event — one of :text_delta,
      #   :tool_call_delta, :done, or :fallback_start
      attr_reader :type

      # @return [Object] the event payload. For :text_delta this is a String
      #   fragment; for :tool_call_delta it is a Hash with partial tool call
      #   data; for :done it is nil or a final summary hash.
      attr_reader :data

      # Creates a new StreamEvent instance.
      #
      # @param type [Symbol] event type (:text_delta, :tool_call_delta, :done, :fallback_start)
      # @param data [Object] event payload
      # @raise [ArgumentError] if the type is not recognized
      def initialize(type:, data: nil)
        unless VALID_TYPES.include?(type)
          raise ArgumentError, "Invalid stream event type: #{type.inspect}. Must be one of: #{VALID_TYPES.join(', ')}"
        end

        @type = type
        @data = data
      end

      # Returns true if this is a text delta event.
      #
      # @return [Boolean]
      def text_delta?
        @type == :text_delta
      end

      # Returns true if this is a tool call delta event.
      #
      # @return [Boolean]
      def tool_call_delta?
        @type == :tool_call_delta
      end

      # Returns true if this is a done/completion event.
      #
      # @return [Boolean]
      def done?
        @type == :done
      end

      # Returns a hash representation of the stream event.
      #
      # @return [Hash]
      def to_h
        { type: @type, data: @data }
      end

      # Returns a human-readable string representation.
      #
      # @return [String]
      def to_s
        "#<RubyPi::LLM::StreamEvent type=#{@type.inspect} data=#{@data.inspect}>"
      end

      alias_method :inspect, :to_s
    end
  end
end
