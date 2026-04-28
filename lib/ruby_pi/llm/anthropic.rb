# frozen_string_literal: true

# lib/ruby_pi/llm/anthropic.rb
#
# LLM provider for Anthropic Claude. Implements the BaseProvider interface using
# the Anthropic Messages API for both synchronous and streaming completions,
# including tool_use block support.

module RubyPi
  module LLM
    # Anthropic Claude provider implementation. Communicates with the Anthropic
    # Messages API to generate text completions, handle tool_use blocks, and
    # stream responses via Server-Sent Events.
    #
    # @example Basic usage
    #   provider = RubyPi::LLM::Anthropic.new(
    #     model: "claude-sonnet-4-20250514",
    #     api_key: ENV["ANTHROPIC_API_KEY"]
    #   )
    #   response = provider.complete(messages: [{ role: "user", content: "Hello!" }])
    #   puts response.content
    class Anthropic < BaseProvider
      # Base URL for the Anthropic Messages API.
      BASE_URL = "https://api.anthropic.com"

      # Anthropic API version header value.
      API_VERSION = "2023-06-01"

      # Default maximum tokens for a response.
      DEFAULT_MAX_TOKENS = 4096

      # Creates a new Anthropic provider instance.
      #
      # @param model [String] the Claude model identifier (e.g., "claude-sonnet-4-20250514")
      # @param api_key [String, nil] Anthropic API key (falls back to global config)
      # @param max_tokens [Integer] maximum tokens to generate (default: 4096)
      # @param options [Hash] additional options passed to BaseProvider
      def initialize(model: nil, api_key: nil, max_tokens: DEFAULT_MAX_TOKENS, **options)
        super(**options)
        config = RubyPi.configuration
        @model = model || config.default_anthropic_model
        @api_key = api_key || config.anthropic_api_key
        @max_tokens = max_tokens
      end

      # Returns the Claude model identifier.
      #
      # @return [String]
      def model_name
        @model
      end

      # Returns :anthropic as the provider identifier.
      #
      # @return [Symbol]
      def provider_name
        :anthropic
      end

      private

      # Performs the completion request against the Anthropic API.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] whether to use streaming
      # @yield [event] streaming events if stream is true
      # @return [RubyPi::LLM::Response]
      def perform_complete(messages:, tools:, stream:, &block)
        body = build_request_body(messages, tools, stream)

        if stream && block_given?
          perform_streaming_request(body, &block)
        else
          perform_standard_request(body)
        end
      end

      # Builds the Anthropic API request body from messages and tools.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] whether streaming is enabled
      # @return [Hash] the request body
      def build_request_body(messages, tools, stream)
        # Separate system message from conversation messages
        system_message = nil
        conversation = []

        messages.each do |msg|
          role = (msg[:role] || msg["role"]).to_s
          content = msg[:content] || msg["content"]

          if role == "system"
            system_message = content.to_s
          else
            conversation << { role: role, content: content.to_s }
          end
        end

        body = {
          model: @model,
          max_tokens: @max_tokens,
          messages: conversation
        }

        body[:system] = system_message if system_message
        body[:stream] = true if stream

        unless tools.empty?
          body[:tools] = tools.map { |t| format_tool(t) }
        end

        body
      end

      # Converts a tool definition to Anthropic's tool format.
      # Accepts either a RubyPi::Tools::Definition or a plain Hash.
      #
      # @param tool [RubyPi::Tools::Definition, Hash] tool definition
      # @return [Hash] Anthropic tool definition
      def format_tool(tool)
        return tool.to_anthropic_format if tool.respond_to?(:to_anthropic_format)

        {
          name: tool[:name] || tool["name"],
          description: tool[:description] || tool["description"] || "",
          input_schema: tool[:parameters] || tool["parameters"] || { type: "object", properties: {} }
        }
      end

      # Executes a standard (non-streaming) request to the Anthropic API.
      #
      # @param body [Hash] the request body
      # @return [RubyPi::LLM::Response]
      def perform_standard_request(body)
        conn = build_connection(
          base_url: BASE_URL,
          headers: default_headers
        )

        response = conn.post("/v1/messages") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        handle_error_response(response) unless response.success?
        parse_response(JSON.parse(response.body))
      end

      # Executes a streaming request to the Anthropic API, yielding events.
      #
      # @param body [Hash] the request body
      # @yield [event] StreamEvent objects
      # @return [RubyPi::LLM::Response] final aggregated response
      def perform_streaming_request(body, &block)
        conn = build_connection(
          base_url: BASE_URL,
          headers: default_headers
        )

        accumulated_text = +""
        accumulated_tool_calls = []
        current_tool_call = nil
        current_tool_json = +""
        usage_data = {}
        finish_reason = nil

        response = conn.post("/v1/messages") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        handle_error_response(response) unless response.success?

        # Parse SSE events from the response body
        parse_sse_events(response.body) do |data|
          event_type = data["type"]

          case event_type
          when "content_block_start"
            content_block = data["content_block"] || {}
            if content_block["type"] == "tool_use"
              current_tool_call = {
                id: content_block["id"],
                name: content_block["name"]
              }
              current_tool_json = +""
            end

          when "content_block_delta"
            delta = data["delta"] || {}
            if delta["type"] == "text_delta"
              text = delta["text"] || ""
              accumulated_text << text
              block.call(StreamEvent.new(type: :text_delta, data: text))
            elsif delta["type"] == "input_json_delta"
              json_chunk = delta["partial_json"] || ""
              current_tool_json << json_chunk
              block.call(StreamEvent.new(type: :tool_call_delta, data: {
                id: current_tool_call&.dig(:id),
                partial_json: json_chunk
              }))
            end

          when "content_block_stop"
            if current_tool_call
              arguments = current_tool_json.empty? ? {} : JSON.parse(current_tool_json)
              accumulated_tool_calls << ToolCall.new(
                id: current_tool_call[:id],
                name: current_tool_call[:name],
                arguments: arguments
              )
              current_tool_call = nil
              current_tool_json = +""
            end

          when "message_delta"
            delta = data["delta"] || {}
            finish_reason = delta["stop_reason"]
            if data.key?("usage")
              usage_info = data["usage"]
              usage_data[:completion_tokens] = usage_info["output_tokens"]
            end

          when "message_start"
            if data.dig("message", "usage")
              usage_info = data["message"]["usage"]
              usage_data[:prompt_tokens] = usage_info["input_tokens"]
            end
          end
        end

        # Signal completion
        block.call(StreamEvent.new(type: :done))

        # Calculate total tokens
        if usage_data[:prompt_tokens] && usage_data[:completion_tokens]
          usage_data[:total_tokens] = usage_data[:prompt_tokens] + usage_data[:completion_tokens]
        end

        Response.new(
          content: accumulated_text.empty? ? nil : accumulated_text,
          tool_calls: accumulated_tool_calls,
          usage: usage_data,
          finish_reason: normalize_finish_reason(finish_reason)
        )
      end

      # Returns the default HTTP headers required by the Anthropic API.
      #
      # @return [Hash] headers hash
      def default_headers
        {
          "x-api-key" => @api_key.to_s,
          "anthropic-version" => API_VERSION
        }
      end

      # Parses an Anthropic API response hash into a normalized Response object.
      #
      # @param data [Hash] parsed JSON response from Anthropic
      # @return [RubyPi::LLM::Response]
      def parse_response(data)
        content = nil
        tool_calls = []

        (data["content"] || []).each do |block|
          case block["type"]
          when "text"
            content = (content || +"") << block["text"]
          when "tool_use"
            tool_calls << ToolCall.new(
              id: block["id"],
              name: block["name"],
              arguments: block["input"] || {}
            )
          end
        end

        # Extract usage
        usage = {}
        if data.key?("usage")
          usage_info = data["usage"]
          usage = {
            prompt_tokens: usage_info["input_tokens"],
            completion_tokens: usage_info["output_tokens"],
            total_tokens: (usage_info["input_tokens"] || 0) + (usage_info["output_tokens"] || 0)
          }
        end

        Response.new(
          content: content,
          tool_calls: tool_calls,
          usage: usage,
          finish_reason: normalize_finish_reason(data["stop_reason"])
        )
      end

      # Normalizes Anthropic-specific finish reasons to common values.
      #
      # @param reason [String, nil] Anthropic stop reason
      # @return [String, nil] normalized finish reason
      def normalize_finish_reason(reason)
        case reason
        when "end_turn" then "stop"
        when "tool_use" then "tool_calls"
        when "max_tokens" then "max_tokens"
        else reason
        end
      end
    end
  end
end
