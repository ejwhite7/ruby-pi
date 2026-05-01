# frozen_string_literal: true

# lib/ruby_pi/llm/gemini.rb
#
# LLM provider for Google Gemini. Implements the BaseProvider interface using
# the Gemini REST API for both synchronous and streaming completions, including
# tool/function calling support.

require "securerandom"

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
        config = @config
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
        # Separate system messages from conversation messages. Gemini requires
        # system instructions via a dedicated `systemInstruction` field — they
        # cannot appear as entries in `contents`. The Loop prepends a
        # { role: :system } message; we extract it here.
        system_parts = []
        conversation_messages = []

        messages.each do |msg|
          role = (msg[:role] || msg["role"]).to_s
          if role == "system"
            system_parts << (msg[:content] || msg["content"]).to_s
          else
            conversation_messages << msg
          end
        end

        body = {
          contents: conversation_messages.map { |msg| format_message(msg) }
        }

        # Inject system instruction when system messages are present
        unless system_parts.empty?
          body[:systemInstruction] = {
            parts: system_parts.map { |text| { text: text } }
          }
        end

        unless tools.empty?
          body[:tools] = [{
            functionDeclarations: tools.map { |t| format_tool(t) }
          }]
        end

        body
      end

      # Converts a normalized message hash to Gemini's content format.
      #
      # Critically, an assistant message that carries `tool_calls` (set by
      # the agent loop after a tool-using turn) must be rendered with one
      # `functionCall` part per tool call. Without those parts, Gemini
      # rejects any subsequent `functionResponse` on the next turn because
      # the response has nothing to correlate against. Earlier versions
      # dropped `tool_calls` here, breaking multi-turn tool use.
      #
      # @param message [Hash] a message with :role and :content keys
      # @return [Hash] Gemini-formatted content object
      def format_message(message)
        role = message[:role]&.to_s || message["role"]&.to_s || "user"
        content = message[:content] || message["content"]

        # Tool-role messages carry function-call results. When the tool name
        # is present, send as a Gemini functionResponse so the model can
        # correlate the result with its earlier functionCall. System messages
        # should have been extracted by build_request_body before reaching
        # this method.
        tool_name = message[:name] || message["name"]
        if role == "tool" && tool_name
          # Gemini's functionResponse expects a structured `response` object.
          # Tool results are pre-serialized by the loop as either a JSON
          # string (success) or an "Error: ..." string (failure). Try to
          # parse JSON so the model receives structured data; fall back to
          # wrapping the raw string under :result for plain-text content.
          response_payload = parse_tool_response(content)
          return {
            role: "user",
            parts: [{
              functionResponse: {
                name: tool_name.to_s,
                response: response_payload
              }
            }]
          }
        end

        # Assistant messages may carry `tool_calls` from a prior turn. Each
        # one must be emitted as a `functionCall` part on the model turn so
        # that the next turn's `functionResponse` has something to bind to.
        if role == "assistant"
          parts = []
          text = content.to_s
          parts << { text: text } unless text.empty?

          tool_calls = message[:tool_calls] || message["tool_calls"]
          if tool_calls.is_a?(Array)
            tool_calls.each do |tc|
              tc_name = (tc[:name] || tc["name"]).to_s
              tc_args = tc[:arguments] || tc["arguments"] || {}
              tc_args = parse_tool_arguments(tc_args)
              parts << { functionCall: { name: tc_name, args: tc_args } }
            end
          end

          # Gemini rejects an empty parts array on a model turn. If the
          # assistant truly had no content and no tool_calls, fall back to
          # an empty text part.
          parts << { text: "" } if parts.empty?

          return { role: "model", parts: parts }
        end

        {
          role: role,
          parts: [{ text: content.to_s }]
        }
      end

      # Best-effort parse of a tool-result string into a structured object
      # for Gemini's `functionResponse.response`. JSON content is returned
      # as-is (wrapped in a hash if it parsed to a non-hash); non-JSON
      # content (e.g., "Error: ...") is wrapped under :result.
      #
      # @param content [String, Hash, nil]
      # @return [Hash]
      def parse_tool_response(content)
        return { result: "" } if content.nil?
        return content if content.is_a?(Hash)

        str = content.to_s
        return { result: str } if str.strip.empty?

        begin
          parsed = JSON.parse(str)
          parsed.is_a?(Hash) ? parsed : { result: parsed }
        rescue JSON::ParserError
          { result: str }
        end
      end

      # Coerce a tool_call.arguments value (Hash, JSON string, or other)
      # into a Hash suitable for Gemini's `functionCall.args`. Malformed
      # or non-Hash values become an empty hash so the request is still
      # well-formed.
      #
      # @param args [Hash, String, nil]
      # @return [Hash]
      def parse_tool_arguments(args)
        return args if args.is_a?(Hash)
        return {} unless args.is_a?(String) && !args.strip.empty?

        begin
          parsed = JSON.parse(args)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end
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

      # Returns the default HTTP headers for Gemini API requests.
      #
      # Issue #13: The API key is now sent via the `x-goog-api-key` header
      # instead of being interpolated into the URL query string. This prevents
      # the key from leaking into debug logs, backtraces, and HTTP intermediary
      # logs (proxies, load balancers, etc.).
      #
      # @return [Hash] headers hash
      def default_headers
        {
          "x-goog-api-key" => @api_key.to_s
        }
      end

      # Executes a standard (non-streaming) request to the Gemini API.
      #
      # Issue #13: Removed API key from the URL query string. The key is now
      # sent via the `x-goog-api-key` header (set in default_headers) to
      # avoid leaking credentials into logs and backtraces.
      #
      # @param body [Hash] the request body
      # @return [RubyPi::LLM::Response]
      def perform_standard_request(body)
        conn = build_connection(base_url: BASE_URL, headers: default_headers)
        url = "/#{API_VERSION}/models/#{@model}:generateContent"

        response = with_transport_errors do
          conn.post(url) do |req|
            req.headers["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          end
        end

        handle_error_response(response) unless response.success?
        parse_response(JSON.parse(response.body))
      end

      # Executes a streaming request to the Gemini API, yielding events.
      #
      # Issue #13: Removed API key from the URL query string. The key is now
      # sent via the `x-goog-api-key` header (set in default_headers).
      #
      # @param body [Hash] the request body
      # @yield [event] StreamEvent objects
      # @return [RubyPi::LLM::Response] final aggregated response
      def perform_streaming_request(body, &block)
        conn = build_connection(base_url: BASE_URL, headers: default_headers)
        url = "/#{API_VERSION}/models/#{@model}:streamGenerateContent?alt=sse"

        accumulated_text = +""
        accumulated_tool_calls = []
        usage_data = {}
        finish_reason = nil

        # Buffer for incomplete SSE lines across on_data chunks. Faraday's
        # on_data callback delivers raw bytes as they arrive from the network,
        # which may split SSE events mid-line. We accumulate a line buffer and
        # process complete lines incrementally so that deltas reach the caller
        # as soon as each SSE event is fully received.
        sse_buffer = +""
        response_status = nil
        error_body = +""

        response = with_transport_errors do
          conn.post(url) do |req|
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

              # Process this SSE event
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
                    # Generate a globally-unique ID per tool call. A simple
                    # length-based counter ("gemini_0", "gemini_1") collides
                    # across turns since each response restarts numbering at
                    # 0, breaking any caller that uses ID as a hash key for
                    # observability or result correlation.
                    id: "gemini_#{SecureRandom.hex(8)}",
                    name: fc["name"],
                    arguments: fc["args"] || {}
                  )
                  accumulated_tool_calls << tool_call
                  block.call(StreamEvent.new(type: :tool_call_delta, data: tool_call.to_h))
                end
              end

              # Parse the actual finish reason from the streaming response
              # instead of hardcoding "stop". Gemini sends finishReason in
              # the candidate object (e.g., "STOP", "MAX_TOKENS", "SAFETY").
              if candidate["finishReason"]
                finish_reason = candidate["finishReason"].downcase
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
          end
          end # conn.post
        end # with_transport_errors

        # When on_data is active, the response body was consumed by the
        # callback. Pass the accumulated error_body so ApiError carries the
        # full server message instead of an empty body.
        unless response.success?
          error_body_str = error_body.empty? ? response.body : error_body
          handle_error_response(response, override_body: error_body_str)
        end

        # Signal completion
        block.call(StreamEvent.new(type: :done))

        Response.new(
          content: accumulated_text.empty? ? nil : accumulated_text,
          tool_calls: accumulated_tool_calls,
          usage: usage_data,
          finish_reason: finish_reason || "stop"
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
              # See note in perform_streaming_request: per-response counters
              # collide across turns, so we generate a globally-unique ID.
              id: "gemini_#{SecureRandom.hex(8)}",
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
