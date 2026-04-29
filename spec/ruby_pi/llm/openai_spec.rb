# frozen_string_literal: true

# spec/ruby_pi/llm/openai_spec.rb
#
# Tests for the OpenAI LLM provider. Validates request formatting, response
# parsing, tool/function calling, streaming events, and retry behavior
# using WebMock to stub all HTTP interactions.

require "spec_helper"

RSpec.describe RubyPi::LLM::OpenAI do
  let(:provider) { described_class.new(model: "gpt-4o", api_key: "test-openai-key") }
  let(:messages) { [{ role: "user", content: "Hello, GPT!" }] }
  let(:api_url) { "https://api.openai.com/v1/chat/completions" }

  describe "#model_name" do
    it "returns the configured model name" do
      expect(provider.model_name).to eq("gpt-4o")
    end
  end

  describe "#provider_name" do
    it "returns :openai" do
      expect(provider.provider_name).to eq(:openai)
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
              id: "chatcmpl-ABC123",
              object: "chat.completion",
              model: "gpt-4o",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Hello! How can I assist you?" },
                finish_reason: "stop"
              }],
              usage: {
                prompt_tokens: 8,
                completion_tokens: 7,
                total_tokens: 15
              }
            })
          )
      end

      it "returns a Response with correct content" do
        response = provider.complete(messages: messages)

        expect(response).to be_a(RubyPi::LLM::Response)
        expect(response.content).to eq("Hello! How can I assist you?")
        expect(response.finish_reason).to eq("stop")
        expect(response.tool_calls).to be_empty
      end

      it "includes usage statistics" do
        response = provider.complete(messages: messages)

        expect(response.usage[:prompt_tokens]).to eq(8)
        expect(response.usage[:completion_tokens]).to eq(7)
        expect(response.usage[:total_tokens]).to eq(15)
      end

      it "sends correct authorization header" do
        provider.complete(messages: messages)

        expect(WebMock).to have_requested(:post, api_url)
          .with(headers: {
            "Authorization" => "Bearer test-openai-key",
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
              id: "chatcmpl-TOOL123",
              object: "chat.completion",
              model: "gpt-4o",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: nil,
                  tool_calls: [{
                    id: "call_abc123",
                    type: "function",
                    function: {
                      name: "get_weather",
                      arguments: '{"location":"London","unit":"fahrenheit"}'
                    }
                  }]
                },
                finish_reason: "tool_calls"
              }],
              usage: { prompt_tokens: 20, completion_tokens: 15, total_tokens: 35 }
            })
          )
      end

      it "parses tool calls from the response" do
        tools = [{ name: "get_weather", description: "Get weather", parameters: { type: "object" } }]
        response = provider.complete(messages: messages, tools: tools)

        expect(response.tool_calls?).to be true
        expect(response.tool_calls.length).to eq(1)
        expect(response.content).to be_nil
        expect(response.finish_reason).to eq("tool_calls")

        tool_call = response.tool_calls.first
        expect(tool_call.id).to eq("call_abc123")
        expect(tool_call.name).to eq("get_weather")
        expect(tool_call.arguments).to eq({ "location" => "London", "unit" => "fahrenheit" })
      end
    end

    context "streaming completion" do
      before do
        # Note: OpenAI streaming includes an initial delta with role but no content,
        # then content deltas, then a final delta with finish_reason.
        sse_body = <<~SSE
          data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

          data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

          data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":null}]}

          data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}

          data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

          data: [DONE]

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

        expect(text_events.length).to eq(3)
        expect(text_events.map(&:data)).to eq(["Hi", " there", "!"])
        expect(done_events.length).to eq(1)

        expect(response.content).to eq("Hi there!")
        expect(response.finish_reason).to eq("stop")
      end
    end

    context "streaming tool calls" do
      before do
        sse_body = <<~SSE
          data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_xyz","type":"function","function":{"name":"search","arguments":""}}]},"finish_reason":null}]}

          data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\\"q\\\""}}]},"finish_reason":null}]}

          data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\\"test\\\"}"}}]},"finish_reason":null}]}

          data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

          data: [DONE]

        SSE

        stub_request(:post, api_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body
          )
      end

      it "accumulates streaming tool calls correctly" do
        events = []
        response = provider.complete(messages: messages, stream: true) do |event|
          events << event
        end

        tool_events = events.select(&:tool_call_delta?)
        expect(tool_events.length).to eq(3)

        expect(response.tool_calls.length).to eq(1)
        tc = response.tool_calls.first
        expect(tc.id).to eq("call_xyz")
        expect(tc.name).to eq("search")
        expect(tc.arguments).to eq({ "q" => "test" })
        expect(response.finish_reason).to eq("tool_calls")
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
                id: "chatcmpl-retry",
                choices: [{
                  index: 0,
                  message: { role: "assistant", content: "Back online!" },
                  finish_reason: "stop"
                }],
                usage: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 }
              })
            }
          )

        response = provider.complete(messages: messages)
        expect(response.content).to eq("Back online!")
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

    context "rate limit error" do
      it "retries on 429 and eventually raises" do
        stub_request(:post, api_url)
          .to_return(status: 429, body: "Too Many Requests")

        expect { provider.complete(messages: messages) }.to raise_error(RubyPi::RateLimitError)
      end
    end
  end

  # -----------------------------------------------------------------------
  # build_request_body — unit tests for tool message formatting
  # -----------------------------------------------------------------------
  describe "#build_request_body (private)" do
    context "full agent loop conversation with tool calls" do
      it "correctly formats a complete tool-calling conversation" do
        messages = [
          { role: :system, content: "You are a helpful assistant." },
          { role: :user, content: "What's the weather in Tokyo?" },
          {
            role: :assistant,
            content: "I'll check the weather.",
            tool_calls: [
              { id: "call_abc", name: "get_weather", arguments: { location: "Tokyo" } }
            ]
          },
          {
            role: :tool,
            content: '{"temp": 22}',
            tool_call_id: "call_abc",
            name: "get_weather"
          },
          { role: :user, content: "Thanks!" }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        formatted = body[:messages]

        # Should have all 5 messages (OpenAI keeps system in messages array)
        expect(formatted.length).to eq(5)

        # Message 1: system
        expect(formatted[0][:role]).to eq("system")
        expect(formatted[0][:content]).to eq("You are a helpful assistant.")

        # Message 2: user
        expect(formatted[1][:role]).to eq("user")
        expect(formatted[1][:content]).to eq("What's the weather in Tokyo?")

        # Message 3: assistant with tool_calls
        expect(formatted[2][:role]).to eq("assistant")
        expect(formatted[2][:content]).to eq("I'll check the weather.")
        expect(formatted[2][:tool_calls]).to be_an(Array)
        expect(formatted[2][:tool_calls].length).to eq(1)

        tc = formatted[2][:tool_calls][0]
        expect(tc[:id]).to eq("call_abc")
        expect(tc[:type]).to eq("function")
        expect(tc[:function][:name]).to eq("get_weather")
        expect(tc[:function][:arguments]).to eq('{"location":"Tokyo"}')

        # Message 4: tool result
        expect(formatted[3][:role]).to eq("tool")
        expect(formatted[3][:tool_call_id]).to eq("call_abc")
        expect(formatted[3][:content]).to eq('{"temp": 22}')

        # Message 5: user follow-up
        expect(formatted[4][:role]).to eq("user")
        expect(formatted[4][:content]).to eq("Thanks!")
      end
    end

    context "structured content preservation" do
      it "passes array content through without calling .to_s" do
        structured_content = [
          { type: "text", text: "Describe this image:" },
          { type: "image_url", image_url: { url: "https://example.com/img.png" } }
        ]

        messages = [{ role: :user, content: structured_content }]
        body = provider.send(:build_request_body, messages, [], false)

        expect(body[:messages][0][:content]).to eq(structured_content)
        expect(body[:messages][0][:content]).to be_an(Array)
      end
    end

    context "nil tool_call_id handling" do
      it "uses 'unknown' for nil tool_call_id" do
        messages = [
          { role: :tool, content: "result", tool_call_id: nil, name: "func" }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        expect(body[:messages][0][:tool_call_id]).to eq("unknown")
      end
    end

    context "assistant message without tool_calls" do
      it "does not include tool_calls key" do
        messages = [
          { role: :assistant, content: "Just a plain response." }
        ]

        body = provider.send(:build_request_body, messages, [], false)
        expect(body[:messages][0]).not_to have_key(:tool_calls)
      end
    end
  end
end
