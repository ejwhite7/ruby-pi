# frozen_string_literal: true

# lib/ruby_pi/llm/tool_call.rb
#
# Represents a tool (function) call requested by the LLM. When the model
# decides to invoke a tool, it returns one or more ToolCall objects describing
# which function to call and with what arguments.

module RubyPi
  module LLM
    # A tool call extracted from an LLM response. Contains the unique call ID,
    # the function name, and the parsed arguments hash. Provider-specific
    # formats are normalized into this common structure.
    #
    # @example Handling a tool call
    #   response.tool_calls.each do |tool_call|
    #     result = dispatch(tool_call.name, tool_call.arguments)
    #     # Feed result back into conversation
    #   end
    class ToolCall
      # @return [String] unique identifier for this tool call, used to match
      #   results back to the calling context
      attr_reader :id

      # @return [String] the name of the tool/function to invoke
      attr_reader :name

      # @return [Hash] the parsed arguments to pass to the tool
      attr_reader :arguments

      # Creates a new ToolCall instance.
      #
      # @param id [String] unique call identifier
      # @param name [String] tool/function name
      # @param arguments [Hash] parsed arguments hash
      def initialize(id:, name:, arguments: {})
        @id = id
        @name = name
        @arguments = arguments.is_a?(Hash) ? arguments : parse_arguments(arguments)
      end

      # Returns a hash representation of the tool call for serialization.
      #
      # @return [Hash]
      def to_h
        {
          id: @id,
          name: @name,
          arguments: @arguments
        }
      end

      # Returns a human-readable string representation of the tool call.
      #
      # @return [String]
      def to_s
        "#<RubyPi::LLM::ToolCall id=#{@id.inspect} name=#{@name.inspect} arguments=#{@arguments.inspect}>"
      end

      alias_method :inspect, :to_s

      private

      # Attempts to parse a JSON string into a Hash. Falls back to wrapping
      # the raw value in a hash if parsing fails.
      #
      # @param raw [String, Object] raw arguments data
      # @return [Hash] parsed arguments
      def parse_arguments(raw)
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        { "_raw" => raw.to_s }
      end
    end
  end
end
