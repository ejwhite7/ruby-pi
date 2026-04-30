# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_13_gemini_api_key_spec.rb
#
# Tests for Issue #13: Gemini API key moved from URL query string to header

require "spec_helper"

RSpec.describe "Issue #13: Gemini API key in header instead of URL" do
  let(:provider) { RubyPi::LLM::Gemini.new(model: "gemini-2.0-flash", api_key: "test-gemini-key") }
  let(:messages) { [{ role: "user", content: "Hello!" }] }

  describe "standard request" do
    it "sends API key in x-goog-api-key header, not in URL" do
      # Stub the URL WITHOUT the key= parameter
      stub_request(:post, %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.0-flash:generateContent})
        .with(headers: { "x-goog-api-key" => "test-gemini-key" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({
            candidates: [{
              content: { parts: [{ text: "Hello!" }] },
              finishReason: "STOP"
            }],
            usageMetadata: { promptTokenCount: 5, candidatesTokenCount: 3, totalTokenCount: 8 }
          })
        )

      response = provider.complete(messages: messages)
      expect(response.content).to eq("Hello!")
    end

    it "does not include key= in the request URL" do
      stub_request(:post, %r{generativelanguage\.googleapis\.com})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({
            candidates: [{ content: { parts: [{ text: "Hi" }] }, finishReason: "STOP" }]
          })
        )

      provider.complete(messages: messages)

      # Verify that no request was made with key= in the URL
      expect(WebMock).not_to have_requested(:post, /key=/)
    end
  end

  describe "streaming request" do
    it "sends API key in x-goog-api-key header for streaming" do
      sse_body = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}',
        'data: {"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7}}'
      ].join("\n")

      stub_request(:post, %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.0-flash:streamGenerateContent})
        .with(headers: { "x-goog-api-key" => "test-gemini-key" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: sse_body
        )

      events = []
      response = provider.complete(
        messages: messages,
        tools: [],
        stream: true
      ) { |e| events << e }

      expect(response.content).to eq("Hi")
    end

    it "uses alt=sse without key= in streaming URL" do
      stub_request(:post, %r{streamGenerateContent\?alt=sse})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: 'data: {"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
        )

      provider.complete(messages: messages, stream: true) { |_| }

      # Should NOT have key= in the URL
      expect(WebMock).not_to have_requested(:post, /key=/)
    end
  end

  describe "source code verification" do
    it "does not interpolate api_key into URLs" do
      source = File.read(File.expand_path("../../../lib/ruby_pi/llm/gemini.rb", __dir__))
      # Verify the source does not contain key= followed by interpolation
      expect(source).not_to include("key=" + "\#" + "{")
    end
  end
end
