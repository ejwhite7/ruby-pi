# frozen_string_literal: true

# lib/ruby_pi/llm/gemini.rb
#
# LLM provider for Google Gemini. Implements the BaseProvider interface using
# the Gemini REST API for both synchronous and streaming completions, including
# tool/function calling support.

module RubyPi
  module LLM
    # Google Gemini provider implementation. Communicates with the Gemini
    # generativelanguage API to generate text completions, handle tool calls,
    # and stream responses.
    #
    # @example Basic usage
    #   provider = RubyPi::LLM::Gemini.new(
    #     model: "gemini-2.0-flash",
    #     api_key: ENV["GEMINI_API_KEY"]
    #   )
    #   response = provider.complete(messages: [{ role: "user", content: "Hello!" }])
    #   puts response.content
    class Gemini < BaseProvider
      # Base URL for the Gemini generativelanguage API.
      BASE_URL = "https://generativelanguage.googleapis.com"

      # API version prefix for endpoint paths.
      API_VERSION = "v1beta"

      # Creates a new Gemini provider instance.
      #
      # @param model [String] the Gemini model identifier (e.g., "gemini-2.0-flash")
      # @param api_key [String, nil] Gemini API key (falls back to global config)
      # @param options [Hash] additional options passed to BaseProvider
      def initialize(model: nil, api_key: nil, **options)
        super(**options)
        config = RubyPi.configuration
        @model = model || config.default_gemini_model
        @api_key = api_key || config.gemini_api_key
      end

      # Returns the Gemini model identifier.
      #
      # @return [String]
      def model_name
        @model
      end

      # Returns :gemini as the provider identifier.
      #
      # @return [Symbol]
      def provider_name
        :gemini
      end

      private

      # Performs the completion request against the Gemini API.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] whether to use streaming
      # @yield [event] streaming events if stream is true
      # @return [RubyPi::LLM::Response]
      def perform_complete(messages:, tools:, stream:, &block)
        body = build_request_body(messages, tools)

        if stream && block_given?
          perform_streaming_request(body, &block)
        else
          perform_standard_request(body)
        end
      end

      # Builds the Gemini API request body from messages and tools.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @return [Hash] the request body
      def build_request_body(messages, tools)
        system_parts = []
        contents = []

        messages.each do |msg|
          role = message_role(msg)
          if role == "system"
            content = message_content(msg)
            system_parts << { text: content.to_s } unless content.nil? || content.to_s.empty?
            next
          end

          formatted = format_message(msg)
          contents << formatted if formatted
        end

        body = { contents: contents }
        body[:systemInstruction] = { parts: system_parts } unless system_parts.empty?

        unless tools.empty?
          body[:tools] = [{
            functionDeclarations: tools.map { |t| format_tool(t) }
          }]
        end

        body
      end

      # Converts a normalized message hash to Gemini's content format.
      #
      # @param message [Hash] a message with :role and :content keys
      # @return [Hash, nil] Gemini-formatted content object
      def format_message(message)
        role = message_role(message)
        content = message_content(message)

        case role
        when "assistant"
          parts = []
          parts << { text: content.to_s } unless content.nil? || content.to_s.empty?

          tool_calls = message[:tool_calls] || message["tool_calls"]
          if tool_calls.is_a?(Array)
            tool_calls.each do |tc|
              name = tc[:name] || tc["name"]
              arguments = tc[:arguments] || tc["arguments"] || tc[:input] || tc["input"] || {}
              parts << { functionCall: { name: name, args: normalize_arguments(arguments) } } if name
            end
          end

          return nil if parts.empty?

          { role: "model", parts: parts }
        when "tool"
          name = message[:name] || message["name"] || message[:tool_name] || message["tool_name"]
          response = content
          response = JSON.parse(response) if response.is_a?(String) && response.strip.start_with?("{", "[")
          response = { result: response } unless response.is_a?(Hash)

          {
            role: "user",
            parts: [{
              functionResponse: {
                name: name.to_s,
                response: response
              }
            }]
          }
        else
          {
            role: "user",
            parts: [{ text: content.to_s }]
          }
        end
      rescue JSON::ParserError
        {
          role: "user",
          parts: [{ text: content.to_s }]
        }
      end

      def message_role(message)
        message[:role]&.to_s || message["role"]&.to_s || "user"
      end

      def message_content(message)
        message[:content] || message["content"] || ""
      end

      def normalize_arguments(arguments)
        return arguments if arguments.is_a?(Hash)
        return JSON.parse(arguments) if arguments.is_a?(String) && !arguments.empty?

        {}
      rescue JSON::ParserError
        { "_raw" => arguments.to_s }
      end

      # Converts a tool definition to Gemini's function declaration format.
      # Accepts either a RubyPi::Tools::Definition or a plain Hash.
      #
      # @param tool [RubyPi::Tools::Definition, Hash] tool definition
      # @return [Hash] Gemini function declaration
      def format_tool(tool)
        return tool.to_gemini_format if tool.respond_to?(:to_gemini_format)

        declaration = {
          name: tool[:name] || tool["name"],
          description: tool[:description] || tool["description"] || ""
        }

        params = tool[:parameters] || tool["parameters"]
        declaration[:parameters] = params if params

        declaration
      end

      # Executes a standard (non-streaming) request to the Gemini API.
      #
      # @param body [Hash] the request body
      # @return [RubyPi::LLM::Response]
      def perform_standard_request(body)
        conn = build_connection(base_url: BASE_URL)
        url = "/#{API_VERSION}/models/#{@model}:generateContent?key=#{@api_key}"

        response = conn.post(url) do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        handle_error_response(response) unless response.success?
        parse_response(JSON.parse(response.body))
      end

      # Executes a streaming request to the Gemini API, yielding events.
      #
      # @param body [Hash] the request body
      # @yield [event] StreamEvent objects
      # @return [RubyPi::LLM::Response] final aggregated response
      def perform_streaming_request(body, &block)
        conn = build_connection(base_url: BASE_URL)
        url = "/#{API_VERSION}/models/#{@model}:streamGenerateContent?key=#{@api_key}&alt=sse"

        accumulated_text = +""
        accumulated_tool_calls = []
        usage_data = {}

        response = conn.post(url) do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        handle_error_response(response) unless response.success?

        # Parse SSE events from the response body
        parse_sse_events(response.body) do |data|
          candidates = data.dig("candidates") || []
          candidate = candidates.first
          next unless candidate

          parts = candidate.dig("content", "parts") || []
          parts.each do |part|
            if part.key?("text")
              text_chunk = part["text"]
              accumulated_text << text_chunk
              block.call(StreamEvent.new(type: :text_delta, data: text_chunk))
            elsif part.key?("functionCall")
              fc = part["functionCall"]
              tool_call = ToolCall.new(
                id: "gemini_#{accumulated_tool_calls.length}",
                name: fc["name"],
                arguments: fc["args"] || {}
              )
              accumulated_tool_calls << tool_call
              block.call(StreamEvent.new(type: :tool_call_delta, data: tool_call.to_h))
            end
          end

          # Capture usage metadata if present
          if data.key?("usageMetadata")
            meta = data["usageMetadata"]
            usage_data = {
              prompt_tokens: meta["promptTokenCount"],
              completion_tokens: meta["candidatesTokenCount"],
              total_tokens: meta["totalTokenCount"]
            }
          end
        end

        # Signal completion
        block.call(StreamEvent.new(type: :done))

        Response.new(
          content: accumulated_text.empty? ? nil : accumulated_text,
          tool_calls: accumulated_tool_calls,
          usage: usage_data,
          finish_reason: "stop"
        )
      end

      # Parses a Gemini API response hash into a normalized Response object.
      #
      # @param data [Hash] parsed JSON response from Gemini
      # @return [RubyPi::LLM::Response]
      def parse_response(data)
        candidates = data["candidates"] || []
        candidate = candidates.first || {}

        content = nil
        tool_calls = []

        parts = candidate.dig("content", "parts") || []
        parts.each do |part|
          if part.key?("text")
            content = (content || +"") << part["text"]
          elsif part.key?("functionCall")
            fc = part["functionCall"]
            tool_calls << ToolCall.new(
              id: "gemini_#{tool_calls.length}",
              name: fc["name"],
              arguments: fc["args"] || {}
            )
          end
        end

        # Extract usage metadata
        usage = {}
        if data.key?("usageMetadata")
          meta = data["usageMetadata"]
          usage = {
            prompt_tokens: meta["promptTokenCount"],
            completion_tokens: meta["candidatesTokenCount"],
            total_tokens: meta["totalTokenCount"]
          }
        end

        # Map Gemini finish reason to normalized string
        finish_reason = candidate["finishReason"]&.downcase

        Response.new(
          content: content,
          tool_calls: tool_calls,
          usage: usage,
          finish_reason: finish_reason
        )
      end
    end
  end
end
