# frozen_string_literal: true

# lib/ruby_pi/agent/result.rb
#
# RubyPi::Agent::Result — Immutable value object encapsulating the outcome of
# an agent run. Contains the final text content, full conversation history,
# tool calls that were executed, token usage, turn count, and any error that
# occurred. The agent loop returns a Result when it completes (either by
# receiving a stop signal from the LLM or hitting the max iteration limit).

module RubyPi
  module Agent
    # Value object returned by Agent::Core#run and Agent::Core#continue.
    # Captures everything about the completed agent interaction in a single,
    # inspectable object.
    #
    # @example Inspecting an agent result
    #   result = agent.run("Hello")
    #   if result.success?
    #     puts result.content
    #     puts "Used #{result.turns} turns"
    #     result.tool_calls_made.each { |tc| puts "  Called: #{tc[:tool_name]}" }
    #   else
    #     puts "Error: #{result.error.message}"
    #   end
    class Result
      # @return [String, nil] the final text content from the assistant
      attr_reader :content

      # @return [Array<Hash>] the full conversation history (all messages)
      attr_reader :messages

      # @return [Array<Hash>] tool calls that were executed, each with
      #   :tool_name, :arguments, and :result keys
      attr_reader :tool_calls_made

      # @return [Hash] aggregate token usage with :input_tokens and
      #   :output_tokens keys
      attr_reader :usage

      # @return [Integer] the number of think-act-observe cycles completed
      attr_reader :turns

      # @return [RubyPi::Error, StandardError, nil] the error if the run failed
      attr_reader :error

      # Creates a new Result instance.
      #
      # @param content [String, nil] the final assistant text
      # @param messages [Array<Hash>] full conversation history
      # @param tool_calls_made [Array<Hash>] executed tool call records
      # @param usage [Hash] token usage statistics
      # @param turns [Integer] number of completed cycles
      # @param error [Exception, nil] error if the run failed
      def initialize(content: nil, messages: [], tool_calls_made: [], usage: {}, turns: 0, error: nil)
        @content = content
        @messages = Array(messages).freeze
        @tool_calls_made = Array(tool_calls_made).freeze
        @usage = usage
        @turns = turns
        @error = error
      end

      # Returns true if the agent run completed without error.
      #
      # @return [Boolean] true unless an error is present
      def success?
        @error.nil?
      end

      # Returns a hash representation of the result for serialization.
      # Includes both the error class name and message for full diagnostic
      # context when an error is present.
      #
      # @return [Hash]
      def to_h
        {
          content: @content,
          messages: @messages,
          tool_calls_made: @tool_calls_made,
          usage: @usage,
          turns: @turns,
          error: @error ? { class: @error.class.name, message: @error.message } : nil,
          success: success?
        }
      end

      # Returns a human-readable string representation of the result.
      #
      # @return [String]
      def to_s
        status = success? ? "success" : "error"
        parts = ["status=#{status}", "turns=#{@turns}"]
        parts << "tools=#{@tool_calls_made.size}" unless @tool_calls_made.empty?
        parts << "content=#{@content&.slice(0, 80).inspect}" if @content
        parts << "error=#{@error.class}: #{@error.message}" if @error
        "#<RubyPi::Agent::Result #{parts.join(', ')}>"
      end

      alias_method :inspect, :to_s
    end
  end
end
