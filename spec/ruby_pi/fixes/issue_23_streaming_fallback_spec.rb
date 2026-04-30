# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_23_streaming_fallback_spec.rb
#
# Tests for Issue #23: Streaming + Fallback double-emits text deltas
# When the primary provider streams partial data then fails, those deltas
# should be discarded. The fallback should stream fresh from the start.

require "spec_helper"

RSpec.describe "Issue #23: Streaming + Fallback double-emit prevention" do
  let(:primary) { double("primary", provider_name: :primary, model_name: "primary-model") }
  let(:fallback_provider) { double("fallback", provider_name: :fallback_inner, model_name: "fallback-model") }
  let(:provider) { RubyPi::LLM::Fallback.new(primary: primary, fallback: fallback_provider) }

  describe "when primary succeeds" do
    it "flushes all buffered events to the consumer" do
      events_from_primary = [
        RubyPi::LLM::StreamEvent.new(type: :text_delta, data: "Hello"),
        RubyPi::LLM::StreamEvent.new(type: :text_delta, data: " world"),
        RubyPi::LLM::StreamEvent.new(type: :done)
      ]

      expected_response = RubyPi::LLM::Response.new(
        content: "Hello world", tool_calls: [], usage: {}, finish_reason: "stop"
      )

      allow(primary).to receive(:complete) do |**_args, &block|
        events_from_primary.each { |e| block.call(e) }
        expected_response
      end

      received_events = []
      response = provider.complete(
        messages: [{ role: "user", content: "hi" }],
        tools: [],
        stream: true
      ) { |event| received_events << event }

      expect(received_events.map(&:type)).to eq([:text_delta, :text_delta, :done])
      expect(received_events[0].data).to eq("Hello")
      expect(received_events[1].data).to eq(" world")
      expect(response.content).to eq("Hello world")
    end
  end

  describe "when primary fails mid-stream" do
    it "discards primary deltas and streams only fallback deltas" do
      # Primary emits 2 deltas then explodes
      allow(primary).to receive(:complete) do |**_args, &block|
        block.call(RubyPi::LLM::StreamEvent.new(type: :text_delta, data: "Partial"))
        block.call(RubyPi::LLM::StreamEvent.new(type: :text_delta, data: " from primary"))
        raise RubyPi::ApiError.new("primary failed", status_code: 500)
      end

      # Fallback streams a complete different response
      fallback_events = [
        RubyPi::LLM::StreamEvent.new(type: :text_delta, data: "Complete"),
        RubyPi::LLM::StreamEvent.new(type: :text_delta, data: " fallback response"),
        RubyPi::LLM::StreamEvent.new(type: :done)
      ]

      fallback_response = RubyPi::LLM::Response.new(
        content: "Complete fallback response", tool_calls: [], usage: {}, finish_reason: "stop"
      )

      allow(fallback_provider).to receive(:complete) do |**_args, &block|
        fallback_events.each { |e| block.call(e) }
        fallback_response
      end

      received_events = []
      response = provider.complete(
        messages: [{ role: "user", content: "hi" }],
        tools: [],
        stream: true
      ) { |event| received_events << event }

      # Should only see fallback events, NOT the partial primary events
      text_deltas = received_events.select(&:text_delta?)
      expect(text_deltas.map(&:data)).to eq(["Complete", " fallback response"])
      expect(response.content).to eq("Complete fallback response")

      # Verify no "Partial" content leaked
      all_text = text_deltas.map(&:data).join
      expect(all_text).not_to include("Partial")
      expect(all_text).not_to include("from primary")
    end
  end

  describe "non-streaming fallback" do
    it "falls back normally without streaming" do
      allow(primary).to receive(:complete).and_raise(
        RubyPi::ApiError.new("fail", status_code: 500)
      )

      allow(fallback_provider).to receive(:complete).and_return(
        RubyPi::LLM::Response.new(content: "fallback", tool_calls: [], usage: {}, finish_reason: "stop")
      )

      response = provider.complete(
        messages: [{ role: "user", content: "hi" }],
        tools: [],
        stream: false
      )

      expect(response.content).to eq("fallback")
    end
  end

  describe "authentication errors are not caught" do
    it "does not fall back on AuthenticationError in streaming" do
      allow(primary).to receive(:complete).and_raise(
        RubyPi::AuthenticationError.new("bad key")
      )

      expect {
        provider.complete(
          messages: [{ role: "user", content: "hi" }],
          tools: [],
          stream: true
        ) { |_| }
      }.to raise_error(RubyPi::AuthenticationError)
    end
  end
end
