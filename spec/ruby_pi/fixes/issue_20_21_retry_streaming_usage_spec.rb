# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_20_21_retry_streaming_usage_spec.rb
#
# Tests for Issues #20 and #21:
# - #20: build_connection no longer advertises retry middleware
# - #21: OpenAI streaming usage is populated via stream_options

require "spec_helper"

RSpec.describe "Issues #20-#21: Retry middleware and streaming usage" do
  # Issue #20: faraday-retry removed, docstring fixed
  describe "Issue #20: Dead retry middleware removed" do
    it "does not require faraday/retry in ruby_pi.rb" do
      source = File.read(File.expand_path("../../../lib/ruby_pi.rb", __dir__))
      # The line should be commented out
      expect(source).not_to match(/^require ["']faraday\/retry["']/)
    end

    it "does not mention 'retry middleware' in build_connection docstring" do
      source = File.read(File.expand_path("../../../lib/ruby_pi/llm/base_provider.rb", __dir__))
      # The old docstring said "with retry middleware" — it should be corrected
      expect(source).not_to match(/with retry middleware/)
    end

    it "gemspec does not have active faraday-retry dependency" do
      source = File.read(File.expand_path("../../../ruby-pi.gemspec", __dir__))
      # faraday-retry line should be commented out
      active_dep = source.lines.reject { |l| l.strip.start_with?("#") }
                         .any? { |l| l.include?("faraday-retry") }
      expect(active_dep).to be false
    end
  end

  # Issue #21: OpenAI streaming should include usage data
  describe "Issue #21: OpenAI streaming usage" do
    let(:provider) { RubyPi::LLM::OpenAI.new(model: "gpt-4o", api_key: "test-key") }
    let(:api_url) { "https://api.openai.com/v1/chat/completions" }

    it "includes stream_options in the streaming request body" do
      sse_body = [
        'data: {"choices":[{"delta":{"content":"Hi"},"index":0}]}',
        'data: {"choices":[{"delta":{},"index":0,"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}',
        'data: [DONE]'
      ].join("\n")

      request_body = nil
      stub_request(:post, api_url)
        .with { |req| request_body = JSON.parse(req.body); true }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: sse_body
        )

      provider.complete(
        messages: [{ role: "user", content: "Hi" }],
        stream: true
      ) { |_| }

      expect(request_body["stream"]).to be true
      expect(request_body["stream_options"]).to eq({ "include_usage" => true })
    end

    it "parses usage data from the final SSE chunk" do
      sse_body = [
        'data: {"choices":[{"delta":{"content":"Hello"},"index":0}]}',
        'data: {"choices":[{"delta":{},"index":0,"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}',
        'data: [DONE]'
      ].join("\n")

      stub_request(:post, api_url).to_return(
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: sse_body
      )

      response = provider.complete(
        messages: [{ role: "user", content: "Hi" }],
        stream: true
      ) { |_| }

      expect(response.usage).to eq({
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15
      })
    end

    it "returns empty usage when no usage chunk is present" do
      sse_body = [
        'data: {"choices":[{"delta":{"content":"Hi"},"index":0}]}',
        'data: {"choices":[{"delta":{},"index":0,"finish_reason":"stop"}]}',
        'data: [DONE]'
      ].join("\n")

      stub_request(:post, api_url).to_return(
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: sse_body
      )

      response = provider.complete(
        messages: [{ role: "user", content: "Hi" }],
        stream: true
      ) { |_| }

      expect(response.usage).to eq({})
    end

    it "does not include stream_options in non-streaming requests" do
      request_body = nil
      stub_request(:post, api_url)
        .with { |req| request_body = JSON.parse(req.body); true }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({
            choices: [{ message: { role: "assistant", content: "Hi" }, finish_reason: "stop" }],
            usage: { prompt_tokens: 5, completion_tokens: 2, total_tokens: 7 }
          })
        )

      provider.complete(messages: [{ role: "user", content: "Hi" }])

      expect(request_body).not_to have_key("stream_options")
    end
  end
end
