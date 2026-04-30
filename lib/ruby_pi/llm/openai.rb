# frozen_string_literal: true

# lib/ruby_pi/llm/openai.rb
#
# LLM provider for OpenAI. Implements the BaseProvider interface using the
# OpenAI Chat Completions API for both synchronous and streaming completions,
# including function/tool calling support.

module RubyPi
  module LLM
    # OpenAI provider implementation. Communicates with the OpenAI Chat
    # Completions API to generate text completions, handle tool/function calls,
    # and stream responses via Server-Sent Events.
    #
    # @example Basic usage
    #   provider = RubyPi::LLM::OpenAI.new(
    #     model: "gpt-4o",
    #     api_key: ENV["OPENAI_API_KEY"]
    #   )
    #   response = provider.complete(messages: [{ role: "user", content: "Hello!" }])
    #   puts response.content
    class OpenAI < BaseProvider
      # Base URL for the OpenAI API.
      BASE_URL = "https://api.openai.com"

      # Creates a new OpenAI provider instance.
      #
      # @param model [String] the OpenAI model identifier (e.g., "gpt-4o")
      # @param api_key [String, nil] OpenAI API key (falls back to global config)
      # @param options [Hash] additional options passed to BaseProvider
      def initialize(model: nil, api_key: nil, **options)
        super(**options)
        config = @config
        @model = model || config.default_openai_model
        @api_key = api_key || config.openai_api_key
      end

      # Returns the OpenAI model identifier.
      #
      # @return [String]
      def model_name
        @model
      end

      # Returns :openai as the provider identifier.
      #
      # @return [Symbol]
      def provider_name
        :openai
      end

      private

      # Performs the completion request against the OpenAI API.
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

      # Builds the OpenAI Chat Completions request body.
      #
      # Handles proper formatting of all message types:
      #
      # 1. System messages pass through with role "system" (OpenAI supports them).
      #
      # 2. Tool result messages (role: "tool") are formatted with the required
      #    `tool_call_id` field so OpenAI can match them to the assistant's
      #    tool_calls.
      #
      # 3. Assistant messages with `tool_calls` include the proper OpenAI
      #    tool_calls structure: `{ id, type: "function", function: { name, arguments } }`.
      #
      # Structured content (Arrays, Hashes) is preserved for multimodal content
      # blocks (e.g., vision messages with image_url content parts).
      #
      # Issue #21: When streaming, includes `stream_options: { include_usage: true }`
      # so OpenAI returns usage data in the final SSE chunk.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] whether streaming is enabled
      # @return [Hash] the request body
      def build_request_body(messages, tools, stream)
        body = {
          model: @model,
          messages: messages.map { |msg| format_message(msg) }
        }

        if stream
          body[:stream] = true
          # Issue #21: Request usage data in streaming mode. OpenAI supports
          # returning token usage in the final SSE chunk when this option is set.
          body[:stream_options] = { include_usage: true }
        end

        unless tools.empty?
          body[:tools] = tools.map { |t| format_tool(t) }
        end

        body
      end

      # Converts a normalized message hash to OpenAI's message format.
      #
      # Handles three message types:
      # - Tool messages (role: "tool"): includes tool_call_id for result matching
      # - Assistant messages with tool_calls: includes structured tool_calls array
      # - Standard messages: role + content with structured content preservation
      #
      # @param message [Hash] a message with :role and :content keys
      # @return [Hash] OpenAI-formatted message
      def format_message(message)
        role = (message[:role] || message["role"]).to_s
        content = message[:content] || message["content"]

        case role
        when "tool"
          # OpenAI accepts role "tool" with a required tool_call_id field
          # to match this result back to the assistant's tool_call.
          tool_call_id = message[:tool_call_id] || message["tool_call_id"]

          # Fail fast with a descriptive error instead of sending "unknown" as
          # the tool_call_id. OpenAI requires tool_call_id to match a preceding
          # tool_calls entry; sending "unknown" causes an opaque HTTP 400.
          if tool_call_id.nil? || tool_call_id.to_s.strip.empty?
            raise RubyPi::ProviderError.new(
              "Missing tool_call_id in tool result message. OpenAI requires " \
              "tool_call_id to match a preceding tool_calls entry. Ensure every " \
              "tool result message includes a valid :tool_call_id.",
              provider: :openai
            )
          end

          {
            role: "tool",
            tool_call_id: tool_call_id,
            content: format_content(content)
          }

        when "assistant"
          # Assistant messages may include tool_calls that must be preserved
          # in OpenAI's expected format for conversation continuity.
          build_assistant_message(message, content)

        else
          # System and user messages — preserve structured content as-is
          # for multimodal support (vision, etc.).
          { role: role, content: format_content(content) }
        end
      end

      # Builds an OpenAI-formatted assistant message, including tool_calls
      # when present. OpenAI requires tool_calls in a specific structure:
      # `{ id, type: "function", function: { name, arguments } }` where
      # arguments is a JSON string.
      #
      # @param message [Hash] internal assistant message with optional :tool_calls
      # @param content [String, Array, Hash, nil] the message content
      # @return [Hash] OpenAI-formatted assistant message
      def build_assistant_message(message, content)
        tool_calls = message[:tool_calls] || message["tool_calls"]

        formatted = {
          role: "assistant",
          content: format_content(content)
        }

        # Include tool_calls in OpenAI's expected format if present
        if tool_calls.is_a?(Array) && !tool_calls.empty?
          formatted[:tool_calls] = tool_calls.map do |tc|
            tc_id = tc[:id] || tc["id"]
            tc_name = tc[:name] || tc["name"]
            tc_args = tc[:arguments] || tc["arguments"] || {}

            # OpenAI requires arguments as a JSON string
            args_string = if tc_args.is_a?(String)
                            tc_args
                          elsif tc_args.is_a?(Hash)
                            JSON.generate(tc_args)
                          else
                            "{}"
                          end

            # Fail fast if tool call id is missing — OpenAI requires it for
            # conversation continuity and tool result matching.
            if tc_id.nil? || tc_id.to_s.strip.empty?
              raise RubyPi::ProviderError.new(
                "Missing id in assistant tool_call. OpenAI requires each " \
                "tool_call to have a valid id for result matching.",
                provider: :openai
              )
            end

            {
              id: tc_id,
              type: "function",
              function: {
                name: tc_name || "unknown_function",
                arguments: args_string
              }
            }
          end
        end

        formatted
      end

      # Formats message content for the OpenAI API, preserving structured
      # content (Arrays and Hashes) for multimodal messages (e.g., vision)
      # and only converting simple values to strings.
      #
      # @param content [String, Array, Hash, nil] the raw content value
      # @return [String, Array, Hash, nil] formatted content suitable for OpenAI
      def format_content(content)
        case content
        when Array, Hash
          content
        when nil
          nil
        else
          content.to_s
        end
      end

      # Converts a tool definition to OpenAI's function tool format.
      # Accepts either a RubyPi::Tools::Definition or a plain Hash.
      #
      # @param tool [RubyPi::Tools::Definition, Hash] tool definition
      # @return [Hash] OpenAI tool definition
      def format_tool(tool)
        return tool.to_openai_format if tool.respond_to?(:to_openai_format)

        {
          type: "function",
          function: {
            name: tool[:name] || tool["name"],
            description: tool[:description] || tool["description"] || "",
            parameters: tool[:parameters] || tool["parameters"] || { type: "object", properties: {} }
          }
        }
      end

      # Executes a standard (non-streaming) request to the OpenAI API.
      #
      # @param body [Hash] the request body
      # @return [RubyPi::LLM::Response]
      def perform_standard_request(body)
        conn = build_connection(
          base_url: BASE_URL,
          headers: default_headers
        )

        response = conn.post("/v1/chat/completions") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        handle_error_response(response) unless response.success?
        parse_response(JSON.parse(response.body))
      end

      # Executes a streaming request to the OpenAI API, yielding events.
      #
      # Issue #21: Parses usage data from the final SSE chunk (when
      # stream_options: { include_usage: true } is set in the request).
      # The final chunk contains the aggregated token usage.
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
        tool_call_accumulators = {}
        finish_reason = nil
        # Issue #21: Accumulate usage data from the final SSE chunk
        streaming_usage = {}

        # Buffer for incomplete SSE lines across on_data chunks. Faraday's
        # on_data callback delivers raw bytes as they arrive from the network,
        # which may split SSE events mid-line. We accumulate a line buffer and
        # process complete lines incrementally so that deltas reach the caller
        # as soon as each SSE event is fully received.
        sse_buffer = +""
        response_status = nil
        error_body = +""

        response = conn.post("/v1/chat/completions") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)

          # Use Faraday's on_data callback for real incremental streaming.
          # Without this, Faraday buffers the entire response body before
          # returning — no deltas reach the caller until the model finishes
          # generating (fake streaming).
          req.options.on_data = proc do |chunk, _overall_received_bytes, env|
            response_status ||= env&.status

            # If the HTTP status indicates an error, accumulate the body for
            # the error handler instead of parsing it as SSE events.
            if response_status && response_status >= 400
              error_body << chunk
              next
            end

            sse_buffer << chunk
            # Process all complete lines in the buffer
            while (line_end = sse_buffer.index("\n"))
              line = sse_buffer.slice!(0, line_end + 1).strip
              next if line.empty?
              next unless line.start_with?("data: ")

              data_str = line.sub(/\Adata: /, "")
              next if data_str == "[DONE]"

              begin
                data = JSON.parse(data_str)
              rescue JSON::ParserError
                next
              end

              # Issue #21: Capture usage data from the final SSE chunk.
              # OpenAI sends usage in a dedicated chunk when include_usage is true.
              if data.key?("usage") && data["usage"]
                usage_info = data["usage"]
                streaming_usage = {
                  prompt_tokens: usage_info["prompt_tokens"],
                  completion_tokens: usage_info["completion_tokens"],
                  total_tokens: usage_info["total_tokens"]
                }
              end

              # Process this SSE event
              choices = data["choices"] || []
              choice = choices.first
              next unless choice

              delta = choice["delta"] || {}
              finish_reason = choice["finish_reason"] if choice["finish_reason"]

              # Handle text content deltas
              if delta.key?("content") && delta["content"]
                text = delta["content"]
                accumulated_text << text
                block.call(StreamEvent.new(type: :text_delta, data: text))
              end

              # Handle tool call deltas
              if delta.key?("tool_calls")
                delta["tool_calls"].each do |tc_delta|
                  index = tc_delta["index"] || 0

                  # Initialize accumulator for this tool call
                  tool_call_accumulators[index] ||= { id: nil, name: +"", arguments: +"" }
                  acc = tool_call_accumulators[index]

                  acc[:id] = tc_delta["id"] if tc_delta["id"]

                  if tc_delta.dig("function", "name")
                    acc[:name] << tc_delta["function"]["name"]
                  end

                  if tc_delta.dig("function", "arguments")
                    acc[:arguments] << tc_delta["function"]["arguments"]
                  end

                  block.call(StreamEvent.new(type: :tool_call_delta, data: {
                    index: index,
                    id: acc[:id],
                    name: acc[:name],
                    arguments_fragment: tc_delta.dig("function", "arguments") || ""
                  }))
                end
              end
            end
          end
        end

        # When on_data is active, the response body was consumed by the
        # callback. Pass the accumulated error_body so ApiError carries the
        # full server message instead of an empty body.
        unless response.success?
          error_body_str = error_body.empty? ? response.body : error_body
          handle_error_response(response, override_body: error_body_str)
        end

        # Build final tool calls from accumulators
        # Issue #12: Guard JSON.parse against empty strings. An empty string
        # is truthy in Ruby, so the previous `empty? ? {} : JSON.parse(...)` check
        # was correct for empty strings, but we also guard against malformed JSON
        # from truncated streams.
        tool_calls = tool_call_accumulators.sort_by { |k, _| k }.map do |_, acc|
          arguments = safe_parse_arguments(acc[:arguments])
          ToolCall.new(id: acc[:id], name: acc[:name], arguments: arguments)
        end

        # Signal completion
        block.call(StreamEvent.new(type: :done))

        Response.new(
          content: accumulated_text.empty? ? nil : accumulated_text,
          tool_calls: tool_calls,
          usage: streaming_usage,
          finish_reason: normalize_finish_reason(finish_reason)
        )
      end

      # Returns the default HTTP headers required by the OpenAI API.
      #
      # @return [Hash] headers hash
      def default_headers
        {
          "Authorization" => "Bearer #{@api_key}"
        }
      end

      # Parses an OpenAI Chat Completions response into a normalized Response.
      #
      # Issue #12: Guards JSON.parse(func["arguments"]) against empty strings.
      # An empty string is truthy in Ruby but causes JSON::ParserError. We now
      # check that arguments is a non-empty string before parsing, and rescue
      # JSON::ParserError to wrap in a ProviderError.
      #
      # @param data [Hash] parsed JSON response from OpenAI
      # @return [RubyPi::LLM::Response]
      def parse_response(data)
        choice = (data["choices"] || []).first || {}
        message = choice["message"] || {}

        content = message["content"]
        tool_calls = []

        (message["tool_calls"] || []).each do |tc|
          func = tc["function"] || {}
          arguments = safe_parse_arguments(func["arguments"])
          tool_calls << ToolCall.new(
            id: tc["id"],
            name: func["name"],
            arguments: arguments
          )
        end

        # Extract usage
        usage = {}
        if data.key?("usage")
          usage_info = data["usage"]
          usage = {
            prompt_tokens: usage_info["prompt_tokens"],
            completion_tokens: usage_info["completion_tokens"],
            total_tokens: usage_info["total_tokens"]
          }
        end

        Response.new(
          content: content,
          tool_calls: tool_calls,
          usage: usage,
          finish_reason: normalize_finish_reason(choice["finish_reason"])
        )
      end

      # Normalizes OpenAI-specific finish reasons to common values.
      #
      # @param reason [String, nil] OpenAI finish reason
      # @return [String, nil] normalized finish reason
      def normalize_finish_reason(reason)
        case reason
        when "stop" then "stop"
        when "tool_calls" then "tool_calls"
        when "length" then "max_tokens"
        else reason
        end
      end

      # Safely parses a JSON arguments string into a Hash.
      #
      # Issue #12: Handles nil, empty strings, and malformed JSON gracefully.
      # Previously, `func["arguments"] ? JSON.parse(func["arguments"]) : {}`
      # would crash on empty strings (truthy but unparseable). Now we validate
      # the input and rescue parse errors with a typed ProviderError.
      #
      # @param raw_args [String, Hash, nil] raw arguments from the API
      # @return [Hash] parsed arguments hash
      # @raise [RubyPi::ProviderError] if JSON parsing fails on non-empty input
      def safe_parse_arguments(raw_args)
        # Already a Hash — pass through
        return raw_args if raw_args.is_a?(Hash)

        # nil or non-string — return empty hash
        return {} unless raw_args.is_a?(String)

        # Empty or whitespace-only string — return empty hash
        return {} if raw_args.strip.empty?

        # Attempt to parse the JSON string
        JSON.parse(raw_args)
      rescue JSON::ParserError => e
        raise RubyPi::ProviderError.new(
          "Failed to parse tool call arguments from OpenAI: #{e.message} (raw: #{raw_args.inspect})",
          provider: :openai
        )
      end
    end
  end
end
