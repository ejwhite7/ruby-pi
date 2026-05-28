# frozen_string_literal: true

# spec/ruby_pi/fixes/review_round5_spec.rb
#
# Tests for the round-5 review fixes:
#   R1 — Compaction's summary message is always a :user message that is valid
#        as the FIRST Anthropic message (no leading :assistant). When the first
#        preserved message is itself :user, the summary is merged into it so
#        there are no consecutive same-role messages.
#   R2 — Compaction handles an entirely-:tool preserved window (orphan-strip
#        empties preserved) by emitting a lone :user summary.
#   R3 — BaseProvider#complete does NOT retry deterministic RubyPi::ProviderError
#        (raised during request construction), but still retries ApiError etc.
#   R4 — Anthropic streaming finish_reason is not clobbered to nil by a trailing
#        message_delta that carries no stop_reason.
#   R5 — Gemini finishReason parsing is robust to a non-String payload (to_s
#        guard) on both the standard and streaming paths.

require "spec_helper"

RSpec.describe "Round-5 review fixes" do
  describe "R1/R2: Compaction summary is a valid leading :user message" do
    let(:summary_model) do
      instance_double(
        RubyPi::LLM::Gemini,
        complete: RubyPi::LLM::Response.new(
          content: "SUMMARY", tool_calls: [], usage: {}, finish_reason: "stop"
        )
      )
    end

    def assert_anthropic_valid_ordering(result)
      # First message must be :user (Anthropic rejects a leading :assistant).
      expect(result.first[:role]).to eq(:user)
      # No two consecutive messages share a role.
      result.each_cons(2) do |a, b|
        expect(a[:role]).not_to eq(b[:role]),
          "consecutive #{a[:role]} messages in #{result.map { |m| m[:role] }.inspect}"
      end
    end

    it "merges the summary into the first preserved message when it is :user" do
      compaction = RubyPi::Context::Compaction.new(
        max_tokens: 50, summary_model: summary_model, preserve_last_n: 2
      )
      long = "x" * 400
      msgs = [
        { role: :user, content: long },
        { role: :assistant, content: long },
        { role: :user, content: "keep-me" },  # first preserved == :user
        { role: :assistant, content: "ack" }
      ]

      result = compaction.compact(msgs, "system")

      expect(result.first[:role]).to eq(:user)
      expect(result.first[:content]).to include("[Conversation Summary]")
      expect(result.first[:content]).to include("keep-me") # original text retained
      assert_anthropic_valid_ordering(result)
    end

    it "does not mutate the caller's original preserved message when merging" do
      compaction = RubyPi::Context::Compaction.new(
        max_tokens: 50, summary_model: summary_model, preserve_last_n: 2
      )
      long = "x" * 400
      original = { role: :user, content: "keep-me" }
      msgs = [
        { role: :user, content: long },
        { role: :assistant, content: long },
        original,
        { role: :assistant, content: "ack" }
      ]

      compaction.compact(msgs, "system")

      expect(original[:content]).to eq("keep-me")
    end

    it "emits a standalone :user summary when the first preserved message is :assistant" do
      compaction = RubyPi::Context::Compaction.new(
        max_tokens: 50, summary_model: summary_model, preserve_last_n: 2
      )
      long = "x" * 400
      msgs = [
        { role: :user, content: long },
        { role: :assistant, content: long, tool_calls: [{ id: "t1", name: "x", arguments: {} }] },
        { role: :tool, content: "r", tool_call_id: "t1", name: "x" }, # stripped (orphan)
        { role: :assistant, content: "ack" }                          # becomes first preserved
      ]

      result = compaction.compact(msgs, "system")

      expect(result.none? { |m| m[:role] == :tool }).to be(true)
      expect(result.first[:role]).to eq(:user)
      expect(result.first[:content]).to include("[Conversation Summary]")
      assert_anthropic_valid_ordering(result)
    end

    it "emits a lone :user summary when the preserved window was entirely :tool" do
      compaction = RubyPi::Context::Compaction.new(
        max_tokens: 50, summary_model: summary_model, preserve_last_n: 1
      )
      long = "x" * 400
      msgs = [
        { role: :user, content: long },
        { role: :assistant, content: long, tool_calls: [{ id: "t1", name: "x", arguments: {} }] },
        { role: :tool, content: "r", tool_call_id: "t1", name: "x" } # preserved -> stripped -> empty
      ]

      result = compaction.compact(msgs, "system")

      expect(result.length).to eq(1)
      expect(result.first[:role]).to eq(:user)
      expect(result.first[:content]).to include("[Conversation Summary]")
      expect(result.none? { |m| m[:role] == :tool }).to be(true)
    end
  end

  describe "R3: ProviderError is not retried; ApiError still is" do
    # Minimal concrete provider that fails on a configurable error a counted
    # number of times. complete() is inherited from BaseProvider unchanged.
    let(:provider_class) do
      Class.new(RubyPi::LLM::BaseProvider) do
        attr_reader :attempts

        def initialize(error_to_raise:, **opts)
          super(**opts)
          @error_to_raise = error_to_raise
          @attempts = 0
        end

        def provider_name = :fake
        def model_name = "fake-1"

        def perform_complete(messages:, tools:, stream:, &block)
          @attempts += 1
          raise @error_to_raise
        end
      end
    end

    it "does not retry a deterministic ProviderError (exactly one attempt)" do
      provider = provider_class.new(
        error_to_raise: RubyPi::ProviderError.new("bad request shape", provider: :fake),
        max_retries: 3, retry_base_delay: 0.001, retry_max_delay: 0.002
      )

      expect {
        provider.complete(messages: [], tools: [])
      }.to raise_error(RubyPi::ProviderError)
      expect(provider.attempts).to eq(1)
    end

    it "still retries ApiError up to max_retries (control case)" do
      provider = provider_class.new(
        error_to_raise: RubyPi::ApiError.new("server error", status_code: 500),
        max_retries: 3, retry_base_delay: 0.001, retry_max_delay: 0.002
      )

      expect {
        provider.complete(messages: [], tools: [])
      }.to raise_error(RubyPi::ApiError)
      expect(provider.attempts).to eq(4) # 1 initial + 3 retries
    end
  end

  describe "R4: Anthropic streaming finish_reason is not clobbered" do
    let(:provider) { RubyPi::LLM::Anthropic.new(model: "claude-sonnet-4", api_key: "test") }
    let(:messages) { [{ role: :user, content: "hi" }] }

    it "keeps the stop_reason from an earlier message_delta when a later one omits it" do
      # First message_delta carries the real stop_reason; a trailing
      # message_delta (e.g. carrying only usage) must NOT reset it to nil.
      sse_body = <<~SSE
        data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"usage":{"input_tokens":3}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

        data: {"type":"message_delta","delta":{},"usage":{"output_tokens":2}}

      SSE

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse_body)

      response = provider.complete(messages: messages, stream: true) { |_e| }

      expect(response.finish_reason).to eq("stop") # normalized from "end_turn"
    end
  end

  describe "R5: Gemini finishReason parsing is robust" do
    let(:provider) { RubyPi::LLM::Gemini.new(model: "gemini-2.0-flash", api_key: "test") }
    let(:messages) { [{ role: :user, content: "hi" }] }

    it "does not raise when finishReason is a non-String and coerces via to_s" do
      stub_request(:post, %r{:generateContent}).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        # JSON number parses to an Integer — a non-String finishReason.
        body: JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: 2 }] })
      )

      expect {
        @resp = provider.complete(messages: messages, stream: false)
      }.not_to raise_error
      expect(@resp.finish_reason).to eq("2")
    end

    it "leaves finish_reason nil when finishReason is absent (no raise)" do
      stub_request(:post, %r{:generateContent}).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] } }] })
      )

      expect {
        @resp = provider.complete(messages: messages, stream: false)
      }.not_to raise_error
      expect(@resp.finish_reason).to be_nil
    end
  end
end
