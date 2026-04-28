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

          data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"q\\""}}]},"finish_reason":null}]}

          data: {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"test\\"}"}}]},"finish_reason":null}]}

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
end
