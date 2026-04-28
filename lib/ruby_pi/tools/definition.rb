# frozen_string_literal: true

# lib/ruby_pi/tools/definition.rb
#
# RubyPi::Tools::Definition — Describes a callable tool with its metadata.
#
# A Definition encapsulates everything needed to declare and invoke a tool:
# its name, description, category, parameter schema, and implementation block.
# It also provides format converters for major LLM provider APIs (Gemini,
# Anthropic, OpenAI) so the same tool definition can be used across providers.
#
# Usage:
#   tool = RubyPi::Tools::Definition.new(
#     name: "create_post",
#     description: "Creates a social media post",
#     category: :content,
#     parameters: RubyPi::Schema.object(
#       content: RubyPi::Schema.string("Post content", required: true)
#     )
#   ) { |args| { post_id: "123", status: "created" } }
#
#   tool.call(content: "Hello world")
#   # => { post_id: "123", status: "created" }

module RubyPi
  module Tools
    class Definition
      # @return [Symbol] The unique name identifying this tool.
      attr_reader :name

      # @return [String] A human-readable description of what this tool does.
      attr_reader :description

      # @return [Symbol, nil] An optional category for grouping related tools.
      attr_reader :category

      # @return [Hash] A JSON Schema hash describing the tool's parameters.
      attr_reader :parameters

      # Creates a new tool definition.
      #
      # @param name [String, Symbol] Unique identifier for the tool.
      # @param description [String] What the tool does (shown to the LLM).
      # @param category [Symbol, nil] Optional grouping category.
      # @param parameters [Hash] JSON Schema hash for the tool's input parameters.
      # @yield [Hash] Block that implements the tool logic. Receives a hash of arguments.
      # @raise [ArgumentError] If name or description is missing, or no block given.
      def initialize(name:, description:, category: nil, parameters: {}, &block)
        raise ArgumentError, "Tool name is required" if name.nil? || name.to_s.strip.empty?
        raise ArgumentError, "Tool description is required" if description.nil? || description.strip.empty?
        raise ArgumentError, "Tool implementation block is required" unless block_given?

        @name = name.to_sym
        @description = description
        @category = category&.to_sym
        @parameters = parameters
        @implementation = block
      end

      # Invokes the tool with the given arguments.
      #
      # @param args [Hash] The arguments to pass to the tool implementation.
      # @return [Object] Whatever the implementation block returns.
      def call(args = {})
        @implementation.call(args)
      end

      # Converts this tool definition to Google Gemini function declaration format.
      #
      # Gemini expects:
      #   { name: "...", description: "...", parameters: { ... } }
      #
      # @return [Hash] The tool in Gemini's function declaration format.
      def to_gemini_format
        declaration = {
          name: @name.to_s,
          description: @description
        }
        declaration[:parameters] = @parameters unless @parameters.empty?
        declaration
      end

      # Converts this tool definition to Anthropic's tool format.
      #
      # Anthropic expects:
      #   { name: "...", description: "...", input_schema: { ... } }
      #
      # @return [Hash] The tool in Anthropic's tool format.
      def to_anthropic_format
        tool = {
          name: @name.to_s,
          description: @description
        }
        tool[:input_schema] = @parameters unless @parameters.empty?
        tool
      end

      # Converts this tool definition to OpenAI's function calling format.
      #
      # OpenAI expects:
      #   { type: "function", function: { name: "...", description: "...", parameters: { ... } } }
      #
      # @return [Hash] The tool in OpenAI's function format.
      def to_openai_format
        function = {
          name: @name.to_s,
          description: @description
        }
        function[:parameters] = @parameters unless @parameters.empty?
        {
          type: "function",
          function: function
        }
      end

      # Provides a human-readable string representation of the definition.
      #
      # @return [String] A summary string for debugging/logging.
      def inspect
        "#<RubyPi::Tools::Definition name=#{@name.inspect} category=#{@category.inspect}>"
      end
    end
  end

  # Top-level convenience module for defining tools with a short syntax.
  #
  # Usage:
  #   tool = RubyPi::Tool.define(name: "my_tool", description: "Does stuff") { |args| ... }
  module Tool
    class << self
      # Creates a new tool Definition using the same arguments as Definition.new.
      #
      # This is the primary public API for defining tools. It provides a cleaner
      # entry point than instantiating Definition directly.
      #
      # @param (see RubyPi::Tools::Definition#initialize)
      # @return [RubyPi::Tools::Definition] The constructed tool definition.
      def define(name:, description:, category: nil, parameters: {}, &block)
        Tools::Definition.new(
          name: name,
          description: description,
          category: category,
          parameters: parameters,
          &block
        )
      end
    end
  end
end
