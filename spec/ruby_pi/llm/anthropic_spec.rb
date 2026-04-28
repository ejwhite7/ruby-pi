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
end
