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
      # Handles three critical conversions from the internal message format to
      # Anthropic's API format:
      #
      # 1. System messages (role: "system") are extracted and promoted to the
      #    top-level `system:` parameter, since Anthropic does not allow system
      #    messages in the messages array.
      #
      # 2. Tool result messages (role: "tool") are converted to role: "user"
      #    messages with `tool_result` content blocks. Consecutive tool messages
      #    are grouped into a single user message, as Anthropic requires.
      #
      # 3. Assistant messages that include `tool_calls` are converted to include
      #    `tool_use` content blocks, so the API can match them to subsequent
      #    `tool_result` blocks.
      #
      # Structured content (Arrays, Hashes) is preserved as-is and never
      # coerced via `.to_s`, which would destroy the content block structure.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] whether streaming is enabled
      # @return [Hash] the request body
      def build_request_body(messages, tools, stream)
        system_message = nil
        conversation = []

        messages.each do |msg|
          role = (msg[:role] || msg["role"]).to_s
          content = msg[:content] || msg["content"]

          case role
          when "system"
            # Anthropic requires system prompts as a top-level parameter, not
            # as a message in the conversation array.
            system_message = content.to_s

          when "tool"
            # Internal tool-result messages must be converted to Anthropic's
            # format: role "user" with a tool_result content block. The
            # tool_use_id links this result back to the assistant's tool_use.
            tool_result_block = build_tool_result_block(msg)

            # Group consecutive tool results into a single "user" message.
            # Anthropic requires this because alternating user/assistant roles
            # means multiple tool results from one turn must share one user msg.
            if conversation.last && conversation.last[:role] == "user" &&
               conversation.last[:content].is_a?(Array) &&
               conversation.last[:content].all? { |b| b[:type] == "tool_result" }
              # Append to the existing grouped tool_result user message
              conversation.last[:content] << tool_result_block
            else
              conversation << { role: "user", content: [tool_result_block] }
            end

          when "assistant"
            # Build the assistant message with proper content blocks.
            # If the message contains tool_calls, they must be included as
            # tool_use content blocks so Anthropic can match them to the
            # subsequent tool_result blocks.
            conversation << build_assistant_message(msg, content)

          else
            # Standard user (or other) messages — preserve structured content
            # as-is and only convert simple values to strings.
            conversation << { role: role, content: format_content(content) }
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

      # Builds an Anthropic tool_result content block from an internal tool
      # message. Extracts the tool_call_id and content, handling edge cases
      # like nil IDs or already-structured content.
      #
      # @param msg [Hash] internal tool message with :tool_call_id, :content, :name
      # @return [Hash] Anthropic tool_result content block
      def build_tool_result_block(msg)
        tool_use_id = msg[:tool_call_id] || msg["tool_call_id"]
        content = msg[:content] || msg["content"]

        # Fail fast with a descriptive error instead of sending "unknown" as
        # the tool_use_id. Anthropic requires tool_use_id to match a preceding
        # tool_use block; sending "unknown" causes an opaque HTTP 400 with no
        # useful error message. Raising here gives the developer a clear signal
        # about what went wrong.
        if tool_use_id.nil? || tool_use_id.to_s.strip.empty?
          raise RubyPi::ProviderError.new(
            "Missing tool_call_id in tool result message. Anthropic requires " \
            "tool_use_id to match a preceding tool_use block. Ensure every tool " \
            "result message includes a valid :tool_call_id.",
            provider: :anthropic
          )
        end

        block = {
          type: "tool_result",
          tool_use_id: tool_use_id
        }

        # Content can be a simple string or a structured content array.
        # Preserve structured content as-is; convert simple values to strings.
        if content.is_a?(Array)
          block[:content] = content
        elsif content.is_a?(Hash)
          block[:content] = [content]
        elsif content.nil?
          block[:content] = ""
        else
          block[:content] = content.to_s
        end

        block
      end

      # Builds an Anthropic-formatted assistant message, including tool_use
      # content blocks when the message has tool_calls.
      #
      # Anthropic represents assistant responses as an array of content blocks.
      # Text content becomes `{ type: "text", text: "..." }` blocks, and tool
      # calls become `{ type: "tool_use", id: "...", name: "...", input: {...} }`
      # blocks. Both can appear in the same message.
      #
      # @param msg [Hash] internal assistant message with optional :tool_calls
      # @param content [String, Array, Hash, nil] the message content
      # @return [Hash] Anthropic-formatted assistant message
      def build_assistant_message(msg, content)
        tool_calls = msg[:tool_calls] || msg["tool_calls"]
        content_blocks = []

        # Add text content block if present. Content may already be a structured
        # array (from a previous Anthropic response) — preserve it as-is.
        if content.is_a?(Array)
          content_blocks.concat(content)
        elsif content.is_a?(Hash)
          content_blocks << content
        elsif content && !content.to_s.empty?
          content_blocks << { type: "text", text: content.to_s }
        end

        # Convert internal tool_calls into Anthropic tool_use content blocks.
        # Each tool_call has :id, :name, and :arguments from ToolCall#to_h.
        if tool_calls.is_a?(Array) && !tool_calls.empty?
          tool_calls.each do |tc|
            tc_id = tc[:id] || tc["id"]
            tc_name = tc[:name] || tc["name"]
            tc_args = tc[:arguments] || tc["arguments"] || {}

            # Ensure arguments is a Hash; parse JSON string if needed
            tc_input = if tc_args.is_a?(Hash)
                         tc_args
                       elsif tc_args.is_a?(String) && !tc_args.empty?
                         begin
                           JSON.parse(tc_args)
                         rescue JSON::ParserError
                           { "_raw" => tc_args }
                         end
                       else
                         {}
                       end

            # Fail fast if tool call ID is missing rather than sending "unknown"
            # which causes an opaque Anthropic API 400 error.
            if tc_id.nil? || tc_id.to_s.strip.empty?
              raise RubyPi::ProviderError.new(
                "Missing tool call ID in assistant message tool_calls. Anthropic " \
                "requires each tool_use block to have a unique ID that subsequent " \
                "tool_result blocks reference. Ensure every tool call includes an :id.",
                provider: :anthropic
              )
            end

            content_blocks << {
              type: "tool_use",
              id: tc_id,
              name: tc_name || "unknown",
              input: tc_input
            }
          end
        end

        # If no content blocks were generated (edge case), add an empty text
        # block to satisfy Anthropic's requirement for non-empty content.
        content_blocks << { type: "text", text: "" } if content_blocks.empty?

        { role: "assistant", content: content_blocks }
      end

      # Formats message content for the Anthropic API, preserving structured
      # content (Arrays and Hashes) and only converting simple values to strings.
      #
      # Anthropic accepts both a plain string and an array of content blocks
      # for the `content` field. Calling `.to_s` on structured content would
      # destroy it, so this method passes Arrays and Hashes through unchanged.
      #
      # @param content [String, Array, Hash, nil] the raw content value
      # @return [String, Array, Hash] formatted content suitable for Anthropic
      def format_content(content)
        case content
        when Array, Hash
          content
        when nil
          ""
        else
          content.to_s
        end
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

        # Buffer for incomplete SSE lines across on_data chunks. Faraday's
        # on_data callback delivers raw bytes as they arrive from the network,
        # which may split SSE events mid-line. We accumulate a line buffer and
        # process complete lines incrementally so that deltas reach the caller
        # as soon as each SSE event is fully received — not after the entire
        # response has been buffered.
        sse_buffer = +""
        response_status = nil

        response = conn.post("/v1/messages") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)

          # Use Faraday's on_data callback for real incremental streaming.
          # Without this, Faraday buffers the entire response body before
          # returning, which means no deltas reach the caller until the model
          # finishes generating (fake streaming).
          req.options.on_data = proc do |chunk, overall_received_bytes, env|
            response_status ||= env&.status
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

              # --- process each SSE event exactly as before ---
              process_anthropic_stream_event(
                data, accumulated_text, accumulated_tool_calls,
                current_tool_call, current_tool_json, usage_data, finish_reason, block
              )
              # Update mutable locals from the processing helper
              current_tool_call = @_stream_current_tool_call
              current_tool_json = @_stream_current_tool_json
              finish_reason = @_stream_finish_reason
            end
          end
        end

        # Check for HTTP errors (on_data still fires for error responses)
        handle_error_response(response) unless response.success?

        # Process any remaining data in the buffer after the connection closes
        sse_buffer.each_line do |line|
          line = line.strip
          next if line.empty?
          next unless line.start_with?("data: ")
          data_str = line.sub(/\Adata: /, "")
          next if data_str == "[DONE]"
          begin
            data = JSON.parse(data_str)
          rescue JSON::ParserError
            next
          end
          process_anthropic_stream_event(
            data, accumulated_text, accumulated_tool_calls,
            current_tool_call, current_tool_json, usage_data, finish_reason, block
          )
          current_tool_call = @_stream_current_tool_call
          current_tool_json = @_stream_current_tool_json
          finish_reason = @_stream_finish_reason
        end

        # (Event processing is now handled incrementally by the on_data callback
        # above, which calls process_anthropic_stream_event for each complete
        # SSE event as it arrives from the network.)

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


      # Processes a single Anthropic SSE event during streaming. Called by the
      # on_data callback for each complete SSE event. Updates the mutable
      # accumulator variables and yields deltas to the caller's block.
      #
      # Instance variables @_stream_current_tool_call, @_stream_current_tool_json,
      # and @_stream_finish_reason are used to pass mutable state back to the
      # caller since Ruby closures over local variables in Procs behave differently
      # from method-local variables.
      #
      # @param data [Hash] parsed SSE event payload
      # @param accumulated_text [String] mutable text accumulator
      # @param accumulated_tool_calls [Array] mutable tool call accumulator
      # @param current_tool_call [Hash, nil] current in-progress tool call
      # @param current_tool_json [String] current tool call JSON accumulator
      # @param usage_data [Hash] mutable usage data accumulator
      # @param finish_reason [String, nil] current finish reason
      # @param block [Proc] the caller's streaming block
      # @return [void]
      def process_anthropic_stream_event(data, accumulated_text, accumulated_tool_calls,
                                          current_tool_call, current_tool_json,
                                          usage_data, finish_reason, block)
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

        # Store mutable state back via instance variables so the on_data Proc
        # can read them after this method returns.
        @_stream_current_tool_call = current_tool_call
        @_stream_current_tool_json = current_tool_json
        @_stream_finish_reason = finish_reason
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
