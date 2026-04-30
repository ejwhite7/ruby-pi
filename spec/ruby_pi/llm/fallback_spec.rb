# frozen_string_literal: true

# spec/ruby_pi/llm/fallback_spec.rb
#
# Tests for the Fallback provider wrapper. Validates that the primary provider
# is used when healthy, the fallback activates on errors, and authentication
# errors are not caught by the fallback mechanism.

require "spec_helper"

RSpec.describe RubyPi::LLM::Fallback do
  let(:gemini_url) { "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent" }
  let(:openai_url) { "https://api.openai.com/v1/chat/completions" }

  let(:primary) { RubyPi::LLM::Gemini.new(model: "gemini-2.0-flash", api_key: "test-gemini-key") }
  let(:backup) { RubyPi::LLM::OpenAI.new(model: "gpt-4o", api_key: "test-openai-key") }
  let(:provider) { described_class.new(primary: primary, fallback: backup) }

  let(:messages) { [{ role: "user", content: "Test message" }] }

  let(:openai_success_body) do
    JSON.generate({
      id: "chatcmpl-fallback",
      choices: [{
        index: 0,
        message: { role: "assistant", content: "Fallback response from OpenAI" },
        finish_reason: "stop"
      }],
      usage: { prompt_tokens: 5, completion_tokens: 6, total_tokens: 11 }
    })
  end

  let(:gemini_success_body) do
    JSON.generate({
      candidates: [{
        content: { parts: [{ text: "Primary response from Gemini" }], role: "model" },
        finishReason: "STOP"
      }],
      usageMetadata: { promptTokenCount: 4, candidatesTokenCount: 5, totalTokenCount: 9 }
    })
  end

  describe "#model_name" do
    it "returns the primary provider model name" do
      expect(provider.model_name).to eq("gemini-2.0-flash")
    end
  end

  describe "#provider_name" do
    it "returns :fallback" do
      expect(provider.provider_name).to eq(:fallback)
    end
  end

  describe "#complete" do
    context "when primary succeeds" do
      before do
        stub_request(:post, gemini_url)
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: gemini_success_body)
      end

      it "uses the primary provider" do
        response = provider.complete(messages: messages)

        expect(response.content).to eq("Primary response from Gemini")
        expect(WebMock).to have_requested(:post, gemini_url).once
        expect(WebMock).not_to have_requested(:post, openai_url)
      end
    end

    context "when primary fails with API error" do
      before do
        # Primary fails all retries (3 attempts)
        stub_request(:post, gemini_url)
          .to_return(status: 500, body: "Server Error")

        stub_request(:post, openai_url)
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: openai_success_body)
      end

      it "falls back to the secondary provider" do
        response = provider.complete(messages: messages)

        expect(response.content).to eq("Fallback response from OpenAI")
        expect(WebMock).to have_requested(:post, openai_url).once
      end
    end

    context "when primary fails with rate limit error" do
      before do
        stub_request(:post, gemini_url)
          .to_return(status: 429, body: "Rate limited")

        stub_request(:post, openai_url)
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: openai_success_body)
      end

      it "falls back to the secondary provider" do
        response = provider.complete(messages: messages)

        expect(response.content).to eq("Fallback response from OpenAI")
      end
    end

    context "when primary fails with authentication error" do
      before do
        stub_request(:post, gemini_url)
          .to_return(status: 401, body: "Unauthorized")
      end

      it "does not fall back — propagates the auth error" do
        expect { provider.complete(messages: messages) }.to raise_error(RubyPi::AuthenticationError)
        expect(WebMock).not_to have_requested(:post, openai_url)
      end
    end

    context "when both providers fail" do
      before do
        stub_request(:post, gemini_url)
          .to_return(status: 500, body: "Primary down")

        stub_request(:post, openai_url)
          .to_return(status: 500, body: "Fallback also down")
      end

      it "raises the fallback provider error" do
        expect { provider.complete(messages: messages) }.to raise_error(RubyPi::ApiError)
      end
    end
  end
end
