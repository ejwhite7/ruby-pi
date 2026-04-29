# frozen_string_literal: true

# spec/ruby_pi/llm/anthropic_spec.rb
#
# Tests for the Anthropic Claude LLM provider. Validates request formatting,
# response parsing, tool_use handling, streaming events, and retry behavior
# using WebMock to stub all HTTP interactions.

require "spec_helper"

RSpec.describe RubyPi::LLM::Anthropic do
  let(:provider) { described_class.new(model: "claude-sonnet-4-20250514", api_key: "test-anthropic-key") }
  let(:messages) { [{ role: "user", content: "Hello, Claude!" }] }
  let(:api_url) { "https://api.anthropic.com/v1/messages" }

  describe "#model_name" do
    it "returns the configured model name" do
      expect(provider.model_name).to eq("claude-sonnet-4-20250514")
    end
  end

  describe "#provider_name" do
    it "returns :anthropic" do
      expect(provider.provider_name).to eq(:anthropic)
    end
  end

  describe "#complete" do
    context "successful text completion" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate({
              id: "msg_01XYZ",
              type: "message",
              role: "assistant",
              content: [{ type: "text", text: "Hello! I'm Claude, ready to help." }],
              model: "claude-sonnet-4-20250514",
              stop_reason: "end_turn",
              usage: { input_tokens: 12, output_tokens: 10 }
            })
          )
      end

      it "returns a Response with correct content" do
        response = provider.complete(messages: messages)

        expect(response).to be_a(RubyPi::LLM::Response)
        expect(response.content).to eq("Hello! I'm Claude, ready to help.")
        expect(response.finish_reason).to eq("stop")
        expect(response.tool_calls).to be_empty
      end

      it "includes usage statistics" do
        response = provider.complete(messages: messages)

        expect(response.usage[:prompt_tokens]).to eq(12)
        expect(response.usage[:completion_tokens]).to eq(10)
        expect(response.usage[:total_tokens]).to eq(22)
      end

      it "sends correct headers" do
        provider.complete(messages: messages)

        expect(WebMock).to have_requested(:post, api_url)
          .with(headers: {
            "x-api-key" => "test-anthropic-key",
            "anthropic-version" => "2023-06-01",
            "Content-Type" => "application/json"
          })
      end
    end

    context "tool call response" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate({
              id: "msg_01ABC",
              type: "message",
              role: "assistant",
              content: [
                { type: "text", text: "I'll check the weather for you." },
                {
                  type: "tool_use",
                  id: "toolu_01ABC",
                  name: "get_weather",
                  input: { location: "Tokyo", unit: "celsius" }
                }
              ],
              model: "claude-sonnet-4-20250514",
              stop_reason: "tool_use",
              usage: { input_tokens: 15, output_tokens: 20 }
            })
          )
      end

      it "parses tool calls from the response" do
        tools = [{ name: "get_weather", description: "Get weather", parameters: { type: "object" } }]
        response = provider.complete(messages: messages, tools: tools)

        expect(response.tool_calls?).to be true
        expect(response.tool_calls.length).to eq(1)
        expect(response.content).to eq("I'll check the weather for you.")
        expect(response.finish_reason).to eq("tool_calls")

        tool_call = response.tool_calls.first
        expect(tool_call.id).to eq("toolu_01ABC")
        expect(tool_call.name).to eq("get_weather")
        expect(tool_call.arguments).to eq({ "location" => "Tokyo", "unit" => "celsius" })
      end
    end

    context "streaming completion" do
      before do
        sse_body = <<~SSE
          data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":10}}}

          data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

          data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Good"}}

          data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" morning!"}}

          data: {"type":"content_block_stop","index":0}

          data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

        SSE

        stub_request(:post, api_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body
          )
      end

      it "yields streaming events to the block" do
        events = []
        response = provider.complete(messages: messages, stream: true) do |event|
          events << event
        end

        text_events = events.select(&:text_delta?)
        done_events = events.select(&:done?)

        expect(text_events.length).to eq(2)
        expect(text_events.map(&:data)).to eq(["Good", " morning!"])
        expect(done_events.length).to eq(1)

        expect(response.content).to eq("Good morning!")
        expect(response.usage[:prompt_tokens]).to eq(10)
        expect(response.usage[:completion_tokens]).to eq(5)
      end
    end

    context "retry on transient errors" do
      it "retries on 500 errors and succeeds" do
        stub_request(:post, api_url)
          .to_return(
            { status: 500, body: "Internal Server Error" },
            {
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate({
                id: "msg_retry",
                type: "message",
                role: "assistant",
                content: [{ type: "text", text: "Recovered!" }],
                stop_reason: "end_turn",
                usage: { input_tokens: 5, output_tokens: 3 }
              })
            }
          )

        response = provider.complete(messages: messages)
        expect(response.content).to eq("Recovered!")
      end

      it "raises after exhausting retries" do
        stub_request(:post, api_url)
          .to_return(status: 500, body: "Server Error")

        expect { provider.complete(messages: messages) }.to raise_error(RubyPi::ApiError)
      end
    end

    context "authentication error" do
      it "raises AuthenticationError without retrying" do
        stub_request(:post, api_url)
          .to_return(status: 401, body: "Invalid API Key")

        expect { provider.complete(messages: messages) }.to raise_error(RubyPi::AuthenticationError)
      end
    end

    context "system message handling" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate({
              id: "msg_sys",
              type: "message",
              role: "assistant",
              content: [{ type: "text", text: "I understand the system prompt." }],
              stop_reason: "end_turn",
              usage: { input_tokens: 20, output_tokens: 8 }
            })
          )
      end

      it "separates system messages from conversation" do
        messages_with_system = [
          { role: "system", content: "You are a helpful assistant." },
          { role: "user", content: "Hello!" }
        ]

        provider.complete(messages: messages_with_system)

        expect(WebMock).to have_requested(:post, api_url)
          .with { |req|
            body = JSON.parse(req.body)
            body["system"] == "You are a helpful assistant." &&
              body["messages"].length == 1 &&
              body["messages"][0]["role"] == "user"
          }
      end
    end
  end

  # -----------------------------------------------------------------------
  # build_request_body — unit tests for tool message formatting
  # -----------------------------------------------------------------------
  describe "#build_request_body (private)" do
    # We test the private method directly using #send to validate the message
    # transformation logic without needing HTTP stubs.

    context "full agent loop conversation with tool calls" do
      it "correctly formats a complete tool-calling conversation" do
        # Simulate the exact message sequence produced by Agent::Loop:
        # 1. System prompt
        # 2. User message
        # 3. Assistant response with tool_calls
        # 4. Tool result messages
        # 5. Final user follow-up
        messages = [
          { role: :system, content: "You are a helpful weather assistant." },
          { role: :user, content: "What's the weather in Tokyo?" },
          {
            role: :assistant,
            content: "I'll check the weather for you.",
            tool_calls: [
              { id: "toolu_01ABC", name: "get_weather", arguments: { location: "Tokyo", unit: "celsius" } }
            ]
          },
          {
            role: :tool,
            content: '{"temperature": 22, "condition": "sunny"}',
            tool_call_id: "toolu_01ABC",
            name: "get_weather"
          },
          { role: :user, content: "Thanks! What about London?" }
        ]

        body = provider.send(:build_request_body, messages, [], false)

        # System message should be promoted to top-level parameter
        expect(body[:system]).to eq("You are a helpful weather assistant.")

        # Should have 4 conversation messages (no system in the array)
        conversation = body[:messages]
        expect(conversation.length).to eq(4)

        # Message 1: user message
        expect(conversation[0][:role]).to eq("user")
        expect(conversation[0][:content]).to eq("What's the weather in Tokyo?")

        # Message 2: assistant with tool_use content block
        expect(conversation[1][:role]).to eq("assistant")
        expect(conversation[1][:content]).to be_an(Array)

        text_blocks = conversation[1][:content].select { |b| b[:type] == "text" }
        tool_use_blocks = conversation[1][:content].select { |b| b[:type] == "tool_use" }

        expect(text_blocks.length).to eq(1)
        expect(text_blocks[0][:text]).to eq("I'll check the weather for you.")

        expect(tool_use_blocks.length).to eq(1)
        expect(tool_use_blocks[0][:id]).to eq("toolu_01ABC")
        expect(tool_use_blocks[0][:name]).to eq("get_weather")
        expect(tool_use_blocks[0][:input]).to eq({ location: "Tokyo", unit: "celsius" })

        # Message 3: tool result converted to user with tool_result content block
        expect(conversation[2][:role]).to eq("user")
        expect(conversation[2][:content]).to be_an(Array)
        expect(conversation[2][:content].length).to eq(1)

        tool_result = conversation[2][:content][0]
        expect(tool_result[:type]).to eq("tool_result")
        expect(tool_result[:tool_use_id]).to eq("toolu_01ABC")
        expect(tool_result[:content]).to eq('{"temperature": 22, "condition": "sunny"}')

        # Message 4: follow-up user message
        expect(conversation[3][:role]).to eq("user")
        expect(conversation[3][:content]).to eq("Thanks! What about London?")
      end
    end

    context "multiple consecutive tool results" do
      it "groups consecutive tool messages into a single user message" do
        messages = [
          { role: :user, content: "Check weather and time in Tokyo" },
          {
            role: :assistant,
            content: nil,
            tool_calls: [
              { id: "toolu_01", name: "get_weather", arguments: { location: "Tokyo" } },
              { id: "toolu_02", name: "get_time", arguments: { timezone: "Asia/Tokyo" } }
            ]
          },
          {
            role: :tool,
            content: '{"temp": 22}',
            tool_call_id: "toolu_01",
            name: "get_weather"
          },
          {
            role: :tool,
            content: '{"time": "14:30"}',
            tool_call_id: "toolu_02",
            name: "get_time"
          }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        conversation = body[:messages]

        # Should have 3 messages: user, assistant, grouped tool results
        expect(conversation.length).to eq(3)

        # The tool results should be grouped into a single user message
        tool_msg = conversation[2]
        expect(tool_msg[:role]).to eq("user")
        expect(tool_msg[:content]).to be_an(Array)
        expect(tool_msg[:content].length).to eq(2)

        expect(tool_msg[:content][0][:type]).to eq("tool_result")
        expect(tool_msg[:content][0][:tool_use_id]).to eq("toolu_01")
        expect(tool_msg[:content][0][:content]).to eq('{"temp": 22}')

        expect(tool_msg[:content][1][:type]).to eq("tool_result")
        expect(tool_msg[:content][1][:tool_use_id]).to eq("toolu_02")
        expect(tool_msg[:content][1][:content]).to eq('{"time": "14:30"}')
      end
    end

    context "assistant message without tool_calls" do
      it "formats as a text content block" do
        messages = [
          { role: :user, content: "Hello" },
          { role: :assistant, content: "Hi there!" }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        conversation = body[:messages]

        expect(conversation[1][:role]).to eq("assistant")
        expect(conversation[1][:content]).to be_an(Array)
        expect(conversation[1][:content][0]).to eq({ type: "text", text: "Hi there!" })
      end
    end

    context "assistant message with nil content and tool_calls" do
      it "includes only tool_use blocks when content is nil" do
        messages = [
          { role: :user, content: "Search for something" },
          {
            role: :assistant,
            content: nil,
            tool_calls: [
              { id: "toolu_99", name: "search", arguments: { query: "test" } }
            ]
          }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        assistant_msg = body[:messages][1]

        expect(assistant_msg[:role]).to eq("assistant")
        expect(assistant_msg[:content]).to be_an(Array)
        expect(assistant_msg[:content].length).to eq(1)
        expect(assistant_msg[:content][0][:type]).to eq("tool_use")
        expect(assistant_msg[:content][0][:id]).to eq("toolu_99")
        expect(assistant_msg[:content][0][:name]).to eq("search")
        expect(assistant_msg[:content][0][:input]).to eq({ query: "test" })
      end
    end

    context "structured content preservation" do
      it "passes array content through without calling .to_s" do
        structured_content = [
          { type: "text", text: "Look at this image:" },
          { type: "image", source: { type: "base64", data: "abc123" } }
        ]

        messages = [
          { role: :user, content: structured_content }
        ]

        body = provider.send(:build_request_body, messages, [], false)

        # The content array should be preserved exactly as-is
        expect(body[:messages][0][:content]).to eq(structured_content)
        expect(body[:messages][0][:content]).to be_an(Array)
      end

      it "passes hash content through without calling .to_s" do
        hash_content = { type: "text", text: "just a hash" }

        messages = [
          { role: :user, content: hash_content }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        expect(body[:messages][0][:content]).to eq(hash_content)
        expect(body[:messages][0][:content]).to be_a(Hash)
      end
    end

    context "edge cases" do
      it "handles nil tool_use_id gracefully" do
        messages = [
          { role: :user, content: "test" },
          {
            role: :assistant,
            content: nil,
            tool_calls: [{ id: nil, name: "func", arguments: {} }]
          },
          {
            role: :tool,
            content: "result",
            tool_call_id: nil,
            name: "func"
          }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        conversation = body[:messages]

        # tool_use block should use "unknown" for nil id
        tool_use = conversation[1][:content].find { |b| b[:type] == "tool_use" }
        expect(tool_use[:id]).to eq("unknown")

        # tool_result block should use "unknown" for nil tool_use_id
        tool_result = conversation[2][:content][0]
        expect(tool_result[:tool_use_id]).to eq("unknown")
      end

      it "handles string-keyed messages" do
        messages = [
          { "role" => "system", "content" => "Be helpful" },
          { "role" => "user", "content" => "Hi" },
          {
            "role" => "assistant",
            "content" => "Let me help.",
            "tool_calls" => [
              { "id" => "tc_1", "name" => "search", "arguments" => { "q" => "test" } }
            ]
          },
          {
            "role" => "tool",
            "content" => "found it",
            "tool_call_id" => "tc_1",
            "name" => "search"
          }
        ]

        body = provider.send(:build_request_body, messages, [], false)

        expect(body[:system]).to eq("Be helpful")
        expect(body[:messages].length).to eq(3)
        expect(body[:messages][1][:content]).to be_an(Array)

        tool_use = body[:messages][1][:content].find { |b| b[:type] == "tool_use" }
        expect(tool_use[:id]).to eq("tc_1")
        expect(tool_use[:name]).to eq("search")
      end

      it "handles tool_calls with JSON string arguments" do
        messages = [
          { role: :user, content: "test" },
          {
            role: :assistant,
            content: "checking",
            tool_calls: [
              { id: "tc_1", name: "func", arguments: '{"key": "value"}' }
            ]
          }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        tool_use = body[:messages][1][:content].find { |b| b[:type] == "tool_use" }

        # JSON string arguments should be parsed into a Hash
        expect(tool_use[:input]).to eq({ "key" => "value" })
      end

      it "handles empty conversation gracefully" do
        body = provider.send(:build_request_body, [], [], false)
        expect(body[:messages]).to eq([])
        expect(body[:system]).to be_nil
      end

      it "includes stream flag when streaming is enabled" do
        messages = [{ role: :user, content: "Hi" }]
        body = provider.send(:build_request_body, messages, [], true)
        expect(body[:stream]).to be true
      end

      it "does not include stream flag when streaming is disabled" do
        messages = [{ role: :user, content: "Hi" }]
        body = provider.send(:build_request_body, messages, [], false)
        expect(body).not_to have_key(:stream)
      end

      it "formats tools correctly" do
        messages = [{ role: :user, content: "Hi" }]
        tools = [
          { name: "get_weather", description: "Get weather info", parameters: { type: "object", properties: {} } }
        ]

        body = provider.send(:build_request_body, messages, tools, false)

        expect(body[:tools]).to be_an(Array)
        expect(body[:tools].length).to eq(1)
        expect(body[:tools][0][:name]).to eq("get_weather")
        expect(body[:tools][0][:input_schema]).to eq({ type: "object", properties: {} })
      end
    end
  end
end
