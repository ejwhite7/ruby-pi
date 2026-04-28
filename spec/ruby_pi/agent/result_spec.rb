# frozen_string_literal: true

# spec/ruby_pi/agent/result_spec.rb
#
# Tests for RubyPi::Agent::Result — verifies the immutable value object,
# success? predicate, to_h serialization, and inspect output.

require_relative "../../../lib/ruby_pi/agent/result"

RSpec.describe RubyPi::Agent::Result do
  describe "successful result" do
    let(:messages) { [{ role: :user, content: "Hi" }, { role: :assistant, content: "Hello!" }] }
    let(:tool_calls) { [{ tool_name: "search", arguments: { q: "test" }, result: { value: "found" } }] }

    subject(:result) do
      described_class.new(
        content: "Hello!",
        messages: messages,
        tool_calls_made: tool_calls,
        usage: { input_tokens: 100, output_tokens: 50 },
        turns: 2
      )
    end

    it "returns the content" do
      expect(result.content).to eq("Hello!")
    end

    it "returns the messages" do
      expect(result.messages.size).to eq(2)
    end

    it "freezes the messages array" do
      expect(result.messages).to be_frozen
    end

    it "returns tool_calls_made" do
      expect(result.tool_calls_made.size).to eq(1)
      expect(result.tool_calls_made.first[:tool_name]).to eq("search")
    end

    it "freezes the tool_calls_made array" do
      expect(result.tool_calls_made).to be_frozen
    end

    it "returns usage data" do
      expect(result.usage[:input_tokens]).to eq(100)
      expect(result.usage[:output_tokens]).to eq(50)
    end

    it "returns the turn count" do
      expect(result.turns).to eq(2)
    end

    it "is successful" do
      expect(result.success?).to be true
    end

    it "has no error" do
      expect(result.error).to be_nil
    end
  end

  describe "failed result" do
    let(:error) { RuntimeError.new("LLM call failed") }

    subject(:result) do
      described_class.new(
        error: error,
        turns: 1
      )
    end

    it "is not successful" do
      expect(result.success?).to be false
    end

    it "returns the error" do
      expect(result.error).to eq(error)
      expect(result.error.message).to eq("LLM call failed")
    end

    it "has nil content" do
      expect(result.content).to be_nil
    end
  end

  describe "default values" do
    subject(:result) { described_class.new }

    it "defaults content to nil" do
      expect(result.content).to be_nil
    end

    it "defaults messages to empty frozen array" do
      expect(result.messages).to eq([])
      expect(result.messages).to be_frozen
    end

    it "defaults tool_calls_made to empty frozen array" do
      expect(result.tool_calls_made).to eq([])
      expect(result.tool_calls_made).to be_frozen
    end

    it "defaults usage to empty hash" do
      expect(result.usage).to eq({})
    end

    it "defaults turns to 0" do
      expect(result.turns).to eq(0)
    end

    it "defaults error to nil (success)" do
      expect(result.success?).to be true
    end
  end

  describe "#to_h" do
    it "serializes all fields" do
      result = described_class.new(
        content: "test",
        turns: 1,
        usage: { input_tokens: 10, output_tokens: 5 }
      )
      hash = result.to_h

      expect(hash[:content]).to eq("test")
      expect(hash[:turns]).to eq(1)
      expect(hash[:success]).to be true
      expect(hash[:error]).to be_nil
    end

    it "serializes error message when present" do
      result = described_class.new(error: RuntimeError.new("fail"))
      hash = result.to_h
      expect(hash[:error]).to eq("fail")
      expect(hash[:success]).to be false
    end
  end

  describe "#to_s / #inspect" do
    it "includes status and turns" do
      result = described_class.new(content: "Hello", turns: 3)
      str = result.to_s
      expect(str).to include("success")
      expect(str).to include("turns=3")
    end

    it "includes tool count when tools were used" do
      result = described_class.new(
        tool_calls_made: [{ tool_name: "t1" }],
        turns: 1
      )
      expect(result.inspect).to include("tools=1")
    end

    it "includes error info on failure" do
      result = described_class.new(error: RuntimeError.new("boom"))
      expect(result.to_s).to include("error")
      expect(result.to_s).to include("boom")
    end
  end
end
