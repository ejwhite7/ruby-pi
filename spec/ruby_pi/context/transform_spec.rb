# frozen_string_literal: true

# spec/ruby_pi/context/transform_spec.rb
#
# Tests for RubyPi::Context::Transform — verifies compose, inject_datetime,
# inject_user_preferences, and inject_workspace_context helpers, including
# idempotency (Issue #8: injections must not accumulate across iterations).

require_relative "../../../lib/ruby_pi/agent/state"
require_relative "../../../lib/ruby_pi/context/transform"

RSpec.describe RubyPi::Context::Transform do
  let(:model) { double("model") }

  let(:state) do
    RubyPi::Agent::State.new(
      system_prompt: "You are a test assistant.",
      model: model,
      user_data: {
        prefs: { tone: "professional", language: "en" },
        workspace: { name: "Acme Corp", plan: "enterprise" }
      }
    )
  end

  describe ".inject_datetime" do
    it "returns a callable" do
      transform = described_class.inject_datetime
      expect(transform).to respond_to(:call)
    end

    it "appends current datetime to the system prompt" do
      transform = described_class.inject_datetime
      original = state.system_prompt.dup
      transform.call(state)

      expect(state.system_prompt).to start_with(original)
      expect(state.system_prompt).to include("Current date and time:")
      expect(state.system_prompt).to include("UTC")
    end

    it "includes a properly formatted timestamp" do
      transform = described_class.inject_datetime
      transform.call(state)

      # Match pattern like "2025-01-15 14:30:00 UTC"
      expect(state.system_prompt).to match(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/)
    end

    it "is idempotent — does not accumulate timestamps across multiple calls" do
      # Issue #8: Without the fix, calling inject_datetime N times would
      # append N timestamps, bloating the context window.
      transform = described_class.inject_datetime

      5.times { transform.call(state) }

      # Count occurrences of "Current date and time:" — should be exactly 1
      occurrences = state.system_prompt.scan("Current date and time:").length
      expect(occurrences).to eq(1)
    end

    it "preserves the base system prompt after multiple calls" do
      transform = described_class.inject_datetime
      3.times { transform.call(state) }

      expect(state.system_prompt).to start_with("You are a test assistant.")
    end
  end

  describe ".inject_user_preferences" do
    it "appends preferences to the system prompt" do
      transform = described_class.inject_user_preferences { |s| s.user_data[:prefs] }
      transform.call(state)

      expect(state.system_prompt).to include("[User Preferences]")
      expect(state.system_prompt).to include("tone: professional")
      expect(state.system_prompt).to include("language: en")
    end

    it "does nothing when the block returns nil" do
      transform = described_class.inject_user_preferences { |_s| nil }
      original = state.system_prompt.dup
      transform.call(state)

      expect(state.system_prompt).to eq(original)
    end

    it "handles string preferences" do
      transform = described_class.inject_user_preferences { |_s| "Prefer short answers" }
      transform.call(state)

      expect(state.system_prompt).to include("[User Preferences]")
      expect(state.system_prompt).to include("Prefer short answers")
    end

    it "is idempotent — does not accumulate preferences across multiple calls" do
      # Issue #8: Without the fix, calling inject_user_preferences N times
      # would append N preference blocks.
      transform = described_class.inject_user_preferences { |s| s.user_data[:prefs] }

      5.times { transform.call(state) }

      occurrences = state.system_prompt.scan("[User Preferences]").length
      expect(occurrences).to eq(1)
    end

    it "strips old preferences when block returns nil on subsequent call" do
      transform_with_prefs = described_class.inject_user_preferences { |s| s.user_data[:prefs] }
      transform_with_prefs.call(state)
      expect(state.system_prompt).to include("[User Preferences]")

      transform_nil = described_class.inject_user_preferences { |_s| nil }
      transform_nil.call(state)
      expect(state.system_prompt).not_to include("[User Preferences]")
    end
  end

  describe ".inject_workspace_context" do
    it "appends workspace context to the system prompt" do
      transform = described_class.inject_workspace_context { |s| s.user_data[:workspace] }
      transform.call(state)

      expect(state.system_prompt).to include("[Workspace Context]")
      expect(state.system_prompt).to include("name: Acme Corp")
      expect(state.system_prompt).to include("plan: enterprise")
    end

    it "does nothing when the block returns nil" do
      transform = described_class.inject_workspace_context { |_s| nil }
      original = state.system_prompt.dup
      transform.call(state)

      expect(state.system_prompt).to eq(original)
    end

    it "handles string context" do
      transform = described_class.inject_workspace_context { |_s| "Project: Alpha" }
      transform.call(state)

      expect(state.system_prompt).to include("[Workspace Context]")
      expect(state.system_prompt).to include("Project: Alpha")
    end

    it "is idempotent — does not accumulate workspace context across multiple calls" do
      # Issue #8: Without the fix, calling inject_workspace_context N times
      # would append N workspace blocks, bloating until context window blows.
      transform = described_class.inject_workspace_context { |s| s.user_data[:workspace] }

      5.times { transform.call(state) }

      occurrences = state.system_prompt.scan("[Workspace Context]").length
      expect(occurrences).to eq(1)
    end
  end

  describe ".compose" do
    it "chains multiple transforms in order" do
      t1 = described_class.inject_datetime
      t2 = described_class.inject_user_preferences { |s| s.user_data[:prefs] }
      t3 = described_class.inject_workspace_context { |s| s.user_data[:workspace] }

      composed = described_class.compose(t1, t2, t3)
      composed.call(state)

      expect(state.system_prompt).to include("Current date and time:")
      expect(state.system_prompt).to include("[User Preferences]")
      expect(state.system_prompt).to include("[Workspace Context]")
    end

    it "returns a callable" do
      composed = described_class.compose
      expect(composed).to respond_to(:call)
    end

    it "handles an empty list of transforms" do
      composed = described_class.compose
      original = state.system_prompt.dup
      composed.call(state)
      expect(state.system_prompt).to eq(original)
    end

    it "applies transforms in declaration order" do
      order = []
      t1 = ->(s) { order << :first }
      t2 = ->(s) { order << :second }
      t3 = ->(s) { order << :third }

      composed = described_class.compose(t1, t2, t3)
      composed.call(state)

      expect(order).to eq([:first, :second, :third])
    end

    it "is idempotent when composed transforms are called multiple times" do
      # Issue #8: A composed transform called N times should not accumulate
      # N copies of each injection.
      t1 = described_class.inject_datetime
      t2 = described_class.inject_user_preferences { |s| s.user_data[:prefs] }
      t3 = described_class.inject_workspace_context { |s| s.user_data[:workspace] }

      composed = described_class.compose(t1, t2, t3)

      # Simulate 10 loop iterations
      10.times { composed.call(state) }

      expect(state.system_prompt.scan("Current date and time:").length).to eq(1)
      expect(state.system_prompt.scan("[User Preferences]").length).to eq(1)
      expect(state.system_prompt.scan("[Workspace Context]").length).to eq(1)
      expect(state.system_prompt).to start_with("You are a test assistant.")
    end
  end
end
