# frozen_string_literal: true

# spec/ruby_pi/llm/gemini_spec.rb
#
# Tests for the Google Gemini LLM provider. Validates request formatting,
# response parsing, tool call handling, streaming events, and retry behavior
# using WebMock to stub all HTTP interactions.

require "spec_helper"

RSpec.describe RubyPi::LLM::Gemini do
  let(:provider) { described_class.new(model: "gemini-2.0-flash", api_key: "test-gemini-key") }
  let(:messages) { [{ role: "user", content: "Hello, Gemini!" }] }
  let(:base_url) { "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash" }

  describe "#model_name" do
    it "returns the configured model name" do
      expect(provider.model_name).to eq("gemini-2.0-flash")
    end
  end

  describe "#provider_name" do
    it "returns :gemini" do
      expect(provider.provider_name).to eq(:gemini)
    end
  end

  describe "#complete" do
    context "successful text completion" do
      before do
        stub_request(:post, "#{base_url}:generateContent")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate({
              candidates: [{
                content: {
                  parts: [{ text: "Hello! How can I help you today?" }],
                  role: "model"
                },
                finishReason: "STOP"
              }],
              usageMetadata: {
                promptTokenCount: 5,
                candidatesTokenCount: 8,
                totalTokenCount: 13
              }
            })
          )
      end

      it "returns a Response with correct content" do
        response = provider.complete(messages: messages)

        expect(response).to be_a(RubyPi::LLM::Response)
        expect(response.content).to eq("Hello! How can I help you today?")
        expect(response.finish_reason).to eq("stop")
        expect(response.tool_calls).to be_empty
      end

      it "includes usage statistics" do
        response = provider.complete(messages: messages)

        expect(response.usage[:prompt_tokens]).to eq(5)
        expect(response.usage[:completion_tokens]).to eq(8)
        expect(response.usage[:total_tokens]).to eq(13)
      end
    end

    context "tool call response" do
      before do
        stub_request(:post, "#{base_url}:generateContent")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate({
              candidates: [{
                content: {
                  parts: [{
                    functionCall: {
                      name: "get_weather",
                      args: { location: "San Francisco", unit: "celsius" }
                    }
                  }],
                  role: "model"
                },
                finishReason: "STOP"
              }],
              usageMetadata: {
                promptTokenCount: 10,
                candidatesTokenCount: 5,
                totalTokenCount: 15
              }
            })
          )
      end

      it "parses tool calls from the response" do
        tools = [{ name: "get_weather", description: "Get weather", parameters: { type: "object" } }]
        response = provider.complete(messages: messages, tools: tools)

        expect(response.tool_calls?).to be true
        expect(response.tool_calls.length).to eq(1)

        tool_call = response.tool_calls.first
        expect(tool_call).to be_a(RubyPi::LLM::ToolCall)
        expect(tool_call.name).to eq("get_weather")
        expect(tool_call.arguments).to eq({ "location" => "San Francisco", "unit" => "celsius" })
      end
    end

    context "streaming completion" do
      before do
        sse_body = <<~SSE
          data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}

          data: {"candidates":[{"content":{"parts":[{"text":" World"}],"role":"model"}}]}

          data: {"candidates":[{"content":{"parts":[{"text":"!"}],"role":"model"}}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2,"totalTokenCount":5}}

        SSE

        stub_request(:post, "#{base_url}:streamGenerateContent?alt=sse")
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
        expect(text_events.map(&:data)).to eq(["Hello", " World", "!"])
        expect(done_events.length).to eq(1)

        # Final response should have aggregated content
        expect(response.content).to eq("Hello World!")
      end
    end

    context "retry on transient errors" do
      it "retries on 500 errors and succeeds" do
        call_count = 0

        stub_request(:post, "#{base_url}:generateContent")
          .to_return(
            { status: 500, body: "Internal Server Error" },
            { status: 200, headers: { "Content-Type" => "application/json" },
              body: JSON.generate({
                candidates: [{
                  content: { parts: [{ text: "Success after retry" }], role: "model" },
                  finishReason: "STOP"
                }],
                usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 3, totalTokenCount: 4 }
              })
            }
          )

        response = provider.complete(messages: messages)
        expect(response.content).to eq("Success after retry")
      end

      it "raises after exhausting retries" do
        stub_request(:post, "#{base_url}:generateContent")
          .to_return(status: 500, body: "Server Error")

        expect { provider.complete(messages: messages) }.to raise_error(RubyPi::ApiError)
      end
    end

    context "authentication error" do
      it "raises AuthenticationError without retrying" do
        stub_request(:post, "#{base_url}:generateContent")
          .to_return(status: 401, body: "Unauthorized")

        expect { provider.complete(messages: messages) }.to raise_error(RubyPi::AuthenticationError)
      end
    end

    context "rate limit error" do
      it "retries on 429 and eventually raises" do
        stub_request(:post, "#{base_url}:generateContent")
          .to_return(status: 429, body: "Rate limited", headers: { "Retry-After" => "1" })

        expect { provider.complete(messages: messages) }.to raise_error(RubyPi::RateLimitError)
      end
    end
  end

    context "system message handling" do
      let(:system_messages) do
        [
          { role: :system, content: "You are a helpful assistant." },
          { role: "user", content: "Hello!" }
        ]
      end

      before do
        stub_request(:post, "#{base_url}:generateContent")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate({
              candidates: [{
                content: { parts: [{ text: "Hi there!" }], role: "model" },
                finishReason: "STOP"
              }],
              usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 3, totalTokenCount: 13 }
            })
          )
      end

      it "sends system messages as systemInstruction, not in contents" do
        provider.complete(messages: system_messages)

        expect(WebMock).to have_requested(:post, "#{base_url}:generateContent")
          .with { |req|
            body = JSON.parse(req.body)
            # systemInstruction should be present
            body.key?("systemInstruction") &&
              body["systemInstruction"]["parts"].first["text"] == "You are a helpful assistant." &&
              # contents should only have the user message, not the system message
              body["contents"].length == 1 &&
              body["contents"].first["role"] == "user"
          }
      end

      it "omits systemInstruction when no system messages are present" do
        provider.complete(messages: [{ role: "user", content: "Hello!" }])

        expect(WebMock).to have_requested(:post, "#{base_url}:generateContent")
          .with { |req|
            body = JSON.parse(req.body)
            !body.key?("systemInstruction")
          }
      end
    end

    context "tool result message formatting" do
      let(:tool_messages) do
        [
          { role: "user", content: "What's the weather?" },
          { role: "assistant", content: "" },
          { role: :tool, content: '{"temp": 72}', name: "get_weather", tool_call_id: "gemini_0" }
        ]
      end

      before do
        stub_request(:post, "#{base_url}:generateContent")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate({
              candidates: [{
                content: { parts: [{ text: "It's 72 degrees." }], role: "model" },
                finishReason: "STOP"
              }],
              usageMetadata: { promptTokenCount: 15, candidatesTokenCount: 5, totalTokenCount: 20 }
            })
          )
      end

      it "formats tool messages as functionResponse with user role" do
        provider.complete(messages: tool_messages)

        expect(WebMock).to have_requested(:post, "#{base_url}:generateContent")
          .with { |req|
            body = JSON.parse(req.body)
            tool_msg = body["contents"].find { |c|
              c["parts"]&.any? { |p| p.key?("functionResponse") }
            }
            tool_msg &&
              tool_msg["role"] == "user" &&
              tool_msg["parts"].first["functionResponse"]["name"] == "get_weather"
          }
      end
    end
end
