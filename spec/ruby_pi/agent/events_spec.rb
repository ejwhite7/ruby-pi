# frozen_string_literal: true

# spec/ruby_pi/agent/events_spec.rb
#
# Tests for RubyPi::Agent::Events — verifies the EVENTS constant and the
# EventEmitter mixin's on/emit/off behavior, including multiple handlers,
# error isolation, recursion guard, and unknown event guards.

require_relative "../../../lib/ruby_pi/agent/events"

# Test harness: a plain class that includes EventEmitter
class TestEmitter
  include RubyPi::Agent::EventEmitter
end

RSpec.describe RubyPi::Agent::EventEmitter do
  subject(:emitter) { TestEmitter.new }

  describe "EVENTS constant" do
    it "defines all expected event types" do
      expected = %i[
        text_delta
        tool_call_delta
        tool_execution_start
        tool_execution_end
        turn_start
        turn_end
        agent_end
        error
        compaction
      ]
      expect(RubyPi::Agent::EVENTS).to match_array(expected)
    end

    it "is frozen" do
      expect(RubyPi::Agent::EVENTS).to be_frozen
    end
  end

  describe "#on" do
    it "registers a handler for a valid event" do
      handler = emitter.on(:text_delta) { |_| "handled" }
      expect(handler).to be_a(Proc)
    end

    it "raises ArgumentError for an unknown event" do
      expect {
        emitter.on(:invalid_event) { |_| }
      }.to raise_error(ArgumentError, /Unknown event type/)
    end

    it "allows multiple handlers for the same event" do
      results = []
      emitter.on(:text_delta) { results << :first }
      emitter.on(:text_delta) { results << :second }
      emitter.emit(:text_delta)
      expect(results).to eq([:first, :second])
    end

    it "accepts :tool_call_delta as a valid event" do
      expect {
        emitter.on(:tool_call_delta) { |_| "ok" }
      }.not_to raise_error
    end
  end

  describe "#emit" do
    it "fires registered handlers with the data argument" do
      received = nil
      emitter.on(:text_delta) { |data| received = data }
      emitter.emit(:text_delta, content: "hello")
      expect(received).to eq(content: "hello")
    end

    it "passes an empty hash by default when no data is given" do
      received = nil
      emitter.on(:turn_start) { |data| received = data }
      emitter.emit(:turn_start)
      expect(received).to eq({})
    end

    it "raises ArgumentError for an unknown event" do
      expect {
        emitter.emit(:bogus)
      }.to raise_error(ArgumentError, /Unknown event type/)
    end

    it "calls handlers in registration order" do
      order = []
      emitter.on(:turn_end) { order << 1 }
      emitter.on(:turn_end) { order << 2 }
      emitter.on(:turn_end) { order << 3 }
      emitter.emit(:turn_end)
      expect(order).to eq([1, 2, 3])
    end

    it "does not raise when no handlers are registered" do
      expect { emitter.emit(:agent_end, result: "done") }.not_to raise_error
    end

    it "isolates handler errors and emits :error instead" do
      error_data = nil
      emitter.on(:text_delta) { raise "boom" }
      emitter.on(:error) { |data| error_data = data }
      emitter.emit(:text_delta, content: "test")

      expect(error_data).not_to be_nil
      expect(error_data[:error]).to be_a(RuntimeError)
      expect(error_data[:error].message).to eq("boom")
      expect(error_data[:source]).to eq(:event_handler)
      expect(error_data[:event]).to eq(:text_delta)
    end

    it "does not infinitely recurse when an :error handler raises" do
      # This tests the recursion guard: errors raised inside :error handlers
      # are silently swallowed to prevent unbounded recursion. Without the
      # guard, emit(:error) -> handler raises -> emit(:error) -> ... would
      # cause a stack overflow.
      emitter.on(:error) { raise "error handler also fails" }
      expect { emitter.emit(:error, error: RuntimeError.new("test")) }.not_to raise_error
    end

    it "emits :tool_call_delta events" do
      received = nil
      emitter.on(:tool_call_delta) { |data| received = data }
      emitter.emit(:tool_call_delta, data: { name: "search", partial_args: "{\"q\":" })
      expect(received[:data][:name]).to eq("search")
    end
  end

  describe "#off" do
    it "removes a specific handler" do
      results = []
      handler = emitter.on(:text_delta) { results << :removed }
      emitter.on(:text_delta) { results << :kept }
      emitter.off(:text_delta, &handler)
      emitter.emit(:text_delta)
      expect(results).to eq([:kept])
    end

    it "returns nil when the handler is not found" do
      other_handler = proc { "other" }
      result = emitter.off(:text_delta, &other_handler)
      expect(result).to be_nil
    end

    it "raises ArgumentError for an unknown event" do
      expect {
        emitter.off(:nope) { |_| }
      }.to raise_error(ArgumentError, /Unknown event type/)
    end
  end
end
