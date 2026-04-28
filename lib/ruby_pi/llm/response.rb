# frozen_string_literal: true

# lib/ruby_pi/llm/response.rb
#
# Represents a unified response from any LLM provider. Normalizes the varied
# response formats of Gemini, Anthropic, and OpenAI into a single, consistent
# structure that calling code can depend on regardless of provider.

module RubyPi
  module LLM
    # A normalized response object returned by all LLM providers after a
    # completion request. Encapsulates the generated text content, any tool
    # calls the model wants to invoke, token usage statistics, and the reason
    # the model stopped generating.
    #
    # @example Accessing response data
    #   response = provider.complete(messages: messages)
    #   puts response.content
    #   response.tool_calls.each { |tc| handle_tool(tc) }
    #   puts "Tokens used: #{response.usage[:total_tokens]}"
    class Response
      # @return [String, nil] the generated text content from the model
      attr_reader :content

      # @return [Array<RubyPi::LLM::ToolCall>] tool calls the model wants to invoke
      attr_reader :tool_calls

      # @return [Hash] token usage statistics with keys like :prompt_tokens,
      #   :completion_tokens, :total_tokens
      attr_reader :usage

      # @return [String, nil] the reason the model stopped generating
      #   (e.g., "stop", "tool_calls", "max_tokens")
      attr_reader :finish_reason

      # Creates a new Response instance.
      #
      # @param content [String, nil] the generated text content
      # @param tool_calls [Array<RubyPi::LLM::ToolCall>] list of tool invocations
      # @param usage [Hash] token usage statistics
      # @param finish_reason [String, nil] why the model stopped generating
      def initialize(content: nil, tool_calls: [], usage: {}, finish_reason: nil)
        @content = content
        @tool_calls = Array(tool_calls)
        @usage = usage
        @finish_reason = finish_reason
      end

      # Returns true if the response includes one or more tool calls.
      #
      # @return [Boolean]
      def tool_calls?
        !@tool_calls.empty?
      end

      # Returns a hash representation of the response for serialization.
      #
      # @return [Hash] the response as a plain hash
      def to_h
        {
          content: @content,
          tool_calls: @tool_calls.map(&:to_h),
          usage: @usage,
          finish_reason: @finish_reason
        }
      end

      # Returns a human-readable string representation of the response.
      #
      # @return [String]
      def to_s
        parts = []
        parts << "content=#{@content.inspect}" if @content
        parts << "tool_calls=#{@tool_calls.length}" if tool_calls?
        parts << "finish_reason=#{@finish_reason}" if @finish_reason
        "#<RubyPi::LLM::Response #{parts.join(', ')}>"
      end

      alias_method :inspect, :to_s
    end
  end
end
