# frozen_string_literal: true

# spec/ruby_pi/context/compaction_spec.rb
#
# Tests for RubyPi::Context::Compaction — verifies token estimation,
# compaction triggering, preserve_last_n behavior, and summary injection.

require_relative "../../../lib/ruby_pi/llm/response"
require_relative "../../../lib/ruby_pi/agent/events"
require_relative "../../../lib/ruby_pi/context/compaction"

RSpec.describe RubyPi::Context::Compaction do
  let(:summary_model) { double("summary_model") }
  let(:compaction) do
    described_class.new(
      max_tokens: 100,
      summary_model: summary_model,
      preserve_last_n: 2
    )
  end

  describe "#initialize" do
    it "sets max_tokens" do
      expect(compaction.max_tokens).to eq(100)
    end

    it "sets summary_model" do
      expect(compaction.summary_model).to eq(summary_model)
    end

    it "sets preserve_last_n" do
      expect(compaction.preserve_last_n).to eq(2)
    end

    it "defaults max_tokens to 8000" do
      c = described_class.new(summary_model: summary_model)
      expect(c.max_tokens).to eq(8000)
    end

    it "defaults preserve_last_n to 4" do
      c = described_class.new(summary_model: summary_model)
      expect(c.preserve_last_n).to eq(4)
    end
  end

  describe "#estimate_tokens" do
    it "estimates tokens based on character count" do
      messages = [{ role: :user, content: "Hello world" }] # 11 chars + 40 overhead
      system_prompt = "Be helpful" # 10 chars
      # Total chars: 10 + 11 + 40 = 61, divided by 4 = 15.25, ceil = 16
      result = compaction.estimate_tokens(system_prompt, messages)
      expect(result).to eq(16)
    end

    it "handles empty messages" do
      result = compaction.estimate_tokens("System", [])
      expect(result).to eq(2) # 6 chars / 4 = 1.5, ceil = 2
    end

    it "handles nil content gracefully" do
      messages = [{ role: :tool, content: nil }]
      result = compaction.estimate_tokens("", messages)
      expect(result).to eq(10) # 0 + 0 + 40 = 40 / 4 = 10
    end

    it "accounts for per-message overhead" do
      messages = (1..5).map { |i| { role: :user, content: "msg" } }
      # system: 0, each message: 3 + 40 = 43 chars each, 5 messages = 215, / 4 = 53.75 => 54
      result = compaction.estimate_tokens("", messages)
      expect(result).to eq(54)
    end
  end

  describe "#compact" do
    let(:system_prompt) { "Be helpful" }

    context "when under the token threshold" do
      let(:messages) do
        [{ role: :user, content: "Hi" }] # Very short — well under 100 tokens
      end

      it "returns nil (no compaction needed)" do
        result = compaction.compact(messages, system_prompt)
        expect(result).to be_nil
      end
    end

    context "when over the token threshold" do
      let(:long_content) { "x" * 200 } # 200 chars = ~50 tokens per message
      let(:messages) do
        [
          { role: :user, content: long_content },
          { role: :assistant, content: long_content },
          { role: :user, content: long_content },
          { role: :assistant, content: "Final response" }
        ]
      end

      before do
        allow(summary_model).to receive(:complete).and_return(
          RubyPi::LLM::Response.new(
            content: "Summary of earlier conversation.",
            tool_calls: [],
            usage: {},
            finish_reason: "stop"
          )
        )
      end

      it "returns a compacted message array" do
        result = compaction.compact(messages, system_prompt)
        expect(result).to be_an(Array)
        expect(result).not_to be_nil
      end

      it "preserves the last N messages" do
        result = compaction.compact(messages, system_prompt)
        # preserve_last_n is 2, so last 2 messages should be preserved
        preserved = result.last(2)
        expect(preserved[0][:content]).to eq(long_content)
        expect(preserved[1][:content]).to eq("Final response")
      end

      it "prepends a summary message with role :user (not :system)" do
        result = compaction.compact(messages, system_prompt)
        summary_msg = result.first
        # The summary message must use role :user, not :system, to prevent it from
        # overwriting the actual system prompt in providers like Anthropic that extract
        # system messages into a top-level parameter (last one wins).
        expect(summary_msg[:role]).to eq(:user)
        expect(summary_msg[:content]).to include("Summary of earlier conversation.")
        expect(summary_msg[:content]).to include("[Conversation Summary]")
      end

      it "has fewer messages than the original" do
        result = compaction.compact(messages, system_prompt)
        # 1 summary + 2 preserved = 3, vs original 4
        expect(result.size).to be < messages.size
      end

      it "calls the summary model to generate the summary" do
        compaction.compact(messages, system_prompt)
        expect(summary_model).to have_received(:complete).once
      end
    end

    context "when nothing can be dropped" do
      let(:messages) do
        [
          { role: :user, content: "x" * 400 },
          { role: :assistant, content: "x" * 400 }
        ]
      end

      it "returns nil when preserve_last_n equals message count" do
        # With preserve_last_n=2 and 2 messages, nothing can be dropped
        result = compaction.compact(messages, "test")
        # Even if over threshold, nothing droppable
        expect(result).to be_nil
      end
    end

    context "with an emitter attached" do
      let(:long_content) { "x" * 200 }
      let(:messages) do
        [
          { role: :user, content: long_content },
          { role: :assistant, content: long_content },
          { role: :user, content: long_content },
          { role: :assistant, content: "last" }
        ]
      end

      before do
        allow(summary_model).to receive(:complete).and_return(
          RubyPi::LLM::Response.new(content: "Summary", tool_calls: [], usage: {}, finish_reason: "stop")
        )
      end

      it "emits a :compaction event with dropped_count and summary" do
        emitter = Object.new
        emitter.extend(RubyPi::Agent::EventEmitter)
        compaction.emitter = emitter

        emitted = nil
        emitter.on(:compaction) { |d| emitted = d }

        compaction.compact(messages, "test")

        expect(emitted).not_to be_nil
        expect(emitted[:dropped_count]).to eq(2)
        expect(emitted[:summary]).to eq("Summary")
      end
    end

    context "does not poison the system prompt for Anthropic" do
      let(:long_content) { "x" * 200 }
      let(:messages) do
        [
          { role: :user, content: long_content },
          { role: :assistant, content: long_content },
          { role: :user, content: long_content },
          { role: :assistant, content: "Final response" }
        ]
      end

      before do
        allow(summary_model).to receive(:complete).and_return(
          RubyPi::LLM::Response.new(
            content: "Summary of conversation.",
            tool_calls: [],
            usage: {},
            finish_reason: "stop"
          )
        )
      end

      it "does not include any :system role messages in compacted output" do
        result = compaction.compact(messages, "Be helpful")
        system_messages = result.select { |m| m[:role] == :system }
        # The compacted output should contain zero :system messages; the real system
        # prompt is prepended separately by the Loop, not by compaction.
        expect(system_messages).to be_empty
      end

      it "ensures only one :system message when loop prepends the real prompt" do
        result = compaction.compact(messages, "Be helpful")
        # Simulate what Loop#build_llm_messages does: prepend the real system prompt
        full_messages = [{ role: :system, content: "Be helpful" }] + result
        system_messages = full_messages.select { |m| m[:role] == :system }
        expect(system_messages.size).to eq(1)
        expect(system_messages.first[:content]).to eq("Be helpful")
      end
    end
  end
end