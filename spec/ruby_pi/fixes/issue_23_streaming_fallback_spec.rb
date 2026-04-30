# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_23_streaming_fallback_spec.rb
#
# Tests for Issue #23 + Issue #12:
# - Issue #23: When the primary provider fails mid-stream, the fallback
#   streams fresh from the start. A :fallback_start event signals the
#   consumer to clear partial output.
# - Issue #12: Streaming events now pass through immediately on the happy
#   path instead of being buffered until completion.

require "spec_helper"

RSpec.describe "Issue #23 + #12: Streaming + Fallback" do
  let(:primary) { double("primary", provider_name: :primary, model_name: "primary-model") }
  let(:fallback_provider) { double("fallback", provider_name: :fallback_inner, model_name: "fallback-model") }
  let(:provider) { RubyPi::LLM::Fallback.new(primary: primary, fallback: fallback_provider) }

  describe "when primary succeeds (happy path)" do
    it "streams events directly to the consumer in real-time" do
      events_from_primary = [
        RubyPi::LLM::StreamEvent.new(type: :text_delta, data: "Hello"),
        RubyPi::LLM::StreamEvent.new(type: :text_delta, data: " world"),
        RubyPi::LLM::StreamEvent.new(type: :done)
      ]

      expected_response = RubyPi::LLM::Response.new(
        content: "Hello world", tool_calls: [], usage: {}, finish_reason: "stop"
      )

      # Verify events are delivered immediately (not buffered)
      delivery_order = []
      allow(primary).to receive(:complete) do |**_args, &block|
        events_from_primary.each do |e|
          block.call(e)
          delivery_order << :event_delivered
        end
        delivery_order << :complete_returned
        expected_response
      end

      received_events = []
      response = provider.complete(
        messages: [{ role: "user", content: "hi" }],
        tools: [],
        stream: true
      ) { |event| received_events << event }

      # Events should have been delivered during the complete call,
      # not buffered and flushed afterward.
      expect(delivery_order).to eq([:event_delivered, :event_delivered, :event_delivered, :complete_returned])
      expect(received_events.map(&:type)).to eq([:text_delta, :text_delta, :done])
      expect(received_events[0].data).to eq("Hello")
      expect(received_events[1].data).to eq(" world")
      expect(response.content).to eq("Hello world")
    end
  end

  describe "when primary fails mid-stream" do
    it "emits fallback_start event and streams fallback deltas" do
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

      # Consumer sees: primary deltas + fallback_start + fallback deltas
      # The :fallback_start event signals the consumer to clear partial output.
      event_types = received_events.map(&:type)
      expect(event_types).to include(:fallback_start)

      # The fallback_start event carries metadata about what happened
      fallback_event = received_events.find { |e| e.type == :fallback_start }
      expect(fallback_event.data[:failed_provider]).to eq(:primary)
      expect(fallback_event.data[:error]).to include("primary failed")
      expect(fallback_event.data[:fallback_provider]).to eq(:fallback_inner)

      # Fallback deltas should be present after fallback_start
      fallback_start_idx = received_events.index(fallback_event)
      post_fallback = received_events[(fallback_start_idx + 1)..]
      text_deltas = post_fallback.select(&:text_delta?)
      expect(text_deltas.map(&:data)).to eq(["Complete", " fallback response"])

      expect(response.content).to eq("Complete fallback response")
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
