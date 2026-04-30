# frozen_string_literal: true

# spec/ruby_pi/agent/core_spec.rb
#
# Tests for RubyPi::Agent::Core — verifies agent.run with mocked LLM,
# multi-turn continue, event emission, hooks firing, extension registration
# with introspection, per-agent configuration, and execution options.

require_relative "../../../lib/ruby_pi/errors"
require_relative "../../../lib/ruby_pi/llm/response"
require_relative "../../../lib/ruby_pi/llm/tool_call"
require_relative "../../../lib/ruby_pi/llm/stream_event"
require_relative "../../../lib/ruby_pi/tools/definition"
require_relative "../../../lib/ruby_pi/tools/registry"
require_relative "../../../lib/ruby_pi/tools/result"
require_relative "../../../lib/ruby_pi/tools/executor"
require_relative "../../../lib/ruby_pi/agent/events"
require_relative "../../../lib/ruby_pi/agent/state"
require_relative "../../../lib/ruby_pi/agent/result"
require_relative "../../../lib/ruby_pi/agent/loop"
require_relative "../../../lib/ruby_pi/agent/core"
require_relative "../../../lib/ruby_pi/extensions/base"

RSpec.describe RubyPi::Agent::Core do
  let(:model) { double("model") }
  let(:registry) { RubyPi::Tools::Registry.new }

  let(:agent) do
    described_class.new(
      system_prompt: "You are a test assistant.",
      model: model,
      tools: registry,
      max_iterations: 5
    )
  end

  before do
    allow(model).to receive(:complete).and_return(
      RubyPi::LLM::Response.new(
        content: "Test response",
        tool_calls: [],
        usage: { prompt_tokens: 50, completion_tokens: 25 },
        finish_reason: "stop"
      )
    )
  end

  describe "#initialize" do
    it "creates a State object" do
      expect(agent.state).to be_a(RubyPi::Agent::State)
    end

    it "sets the system prompt on state" do
      expect(agent.state.system_prompt).to eq("You are a test assistant.")
    end

    it "sets max_iterations on state" do
      expect(agent.state.max_iterations).to eq(5)
    end

    it "seeds initial messages into state" do
      initial_messages = [
        { role: :user, content: "Earlier question" },
        { role: :assistant, content: "Earlier answer" }
      ]

      agent = described_class.new(
        system_prompt: "test",
        model: model,
        messages: initial_messages
      )

      expect(agent.state.messages).to eq(initial_messages)
    end

    it "initializes extensions as empty array" do
      expect(agent.extensions).to eq([])
    end

    it "defaults config to nil (uses global)" do
      expect(agent.config).to be_nil
    end
  end

  describe "#run" do
    it "returns an Agent::Result" do
      result = agent.run("Hello")
      expect(result).to be_a(RubyPi::Agent::Result)
    end

    it "returns the LLM content" do
      result = agent.run("Hello")
      expect(result.content).to eq("Test response")
    end

    it "adds the user message to state" do
      agent.run("Hello")
      user_msg = agent.state.messages.find { |m| m[:role] == :user }
      expect(user_msg[:content]).to eq("Hello")
    end

    it "completes in 1 turn for a simple response" do
      result = agent.run("Hello")
      expect(result.turns).to eq(1)
    end

    it "returns success" do
      result = agent.run("Hello")
      expect(result.success?).to be true
    end
  end

  describe "#continue" do
    it "preserves conversation history" do
      agent.run("First message")
      agent.continue("Second message")

      user_msgs = agent.state.messages.select { |m| m[:role] == :user }
      expect(user_msgs.size).to eq(2)
      expect(user_msgs.map { |m| m[:content] }).to eq(["First message", "Second message"])
    end

    it "resets iteration count for new run" do
      agent.run("First")
      expect(agent.state.iteration).to eq(1)

      agent.continue("Second")
      # After continue completes, iteration should be 1 (reset + 1 turn)
      expect(agent.state.iteration).to eq(1)
    end

    it "returns a new Result" do
      agent.run("First")
      result = agent.continue("Follow up")
      expect(result.success?).to be true
      expect(result.content).to eq("Test response")
    end
  end

  describe "event emission" do
    it "emits :agent_end when run completes" do
      agent_end_data = nil
      agent.on(:agent_end) { |d| agent_end_data = d }

      agent.run("Hello")

      expect(agent_end_data).not_to be_nil
      expect(agent_end_data[:success]).to be true
    end

    it "emits :turn_start and :turn_end" do
      events = []
      agent.on(:turn_start) { |d| events << :turn_start }
      agent.on(:turn_end) { |d| events << :turn_end }

      agent.run("Hello")

      expect(events).to include(:turn_start, :turn_end)
    end

    it "allows subscribing to :text_delta" do
      deltas = []
      agent.on(:text_delta) { |d| deltas << d[:content] }

      # The mock doesn't yield streaming events, so deltas should be empty
      agent.run("Hello")
      # This verifies the subscription mechanism works without error
      expect(deltas).to be_an(Array)
    end
  end

  describe "hooks" do
    it "passes before_tool_call hook to state" do
      hook = ->(tc) { tc }
      agent = described_class.new(
        system_prompt: "test",
        model: model,
        before_tool_call: hook
      )
      expect(agent.state.before_tool_call).to eq(hook)
    end

    it "passes after_tool_call hook to state" do
      hook = ->(tc, r) { r }
      agent = described_class.new(
        system_prompt: "test",
        model: model,
        after_tool_call: hook
      )
      expect(agent.state.after_tool_call).to eq(hook)
    end

    it "passes transform_context hook to state" do
      hook = ->(s) { s }
      agent = described_class.new(
        system_prompt: "test",
        model: model,
        transform_context: hook
      )
      expect(agent.state.transform_context).to eq(hook)
    end
  end

  describe "#use (extensions)" do
    it "registers an extension and subscribes its hooks" do
      ext_class = Class.new(RubyPi::Extensions::Base) do
        on_event :agent_end do |data, _agent|
          # This will be captured via the test
        end
      end

      # Should not raise
      expect { agent.use(ext_class) }.not_to raise_error
    end

    it "raises ArgumentError for invalid extension" do
      expect {
        agent.use("not an extension")
      }.to raise_error(ArgumentError, /hooks method/)
    end

    it "extension hooks fire on events" do
      hook_results = []

      ext_class = Class.new(RubyPi::Extensions::Base)
      ext_class.on_event(:agent_end) { |data, _agent| hook_results << :agent_end_fired }

      agent.use(ext_class)
      agent.run("Hello")

      expect(hook_results).to include(:agent_end_fired)
    end

    it "tracks registered extension classes for introspection" do
      ext_class_a = Class.new(RubyPi::Extensions::Base)
      ext_class_b = Class.new(RubyPi::Extensions::Base)

      agent.use(ext_class_a)
      agent.use(ext_class_b)

      expect(agent.extensions).to eq([ext_class_a, ext_class_b])
    end
  end

  describe "per-agent configuration (#33)" do
    it "accepts a config: kwarg" do
      custom_config = RubyPi::Configuration.new
      custom_config.openai_api_key = "per-agent-key"

      agent = described_class.new(
        system_prompt: "test",
        model: model,
        config: custom_config
      )

      expect(agent.config).to eq(custom_config)
      expect(agent.config.openai_api_key).to eq("per-agent-key")
    end

    it "falls back to global config when no per-agent config given" do
      agent = described_class.new(
        system_prompt: "test",
        model: model
      )

      expect(agent.effective_config).to eq(RubyPi.configuration)
    end

    it "returns per-agent config from effective_config when provided" do
      custom_config = RubyPi::Configuration.new
      custom_config.max_retries = 99

      agent = described_class.new(
        system_prompt: "test",
        model: model,
        config: custom_config
      )

      expect(agent.effective_config).to eq(custom_config)
      expect(agent.effective_config.max_retries).to eq(99)
    end
  end

  describe "execution options (#36)" do
    it "accepts execution_mode and tool_timeout kwargs" do
      agent = described_class.new(
        system_prompt: "test",
        model: model,
        execution_mode: :sequential,
        tool_timeout: 60
      )

      # These are passed through to Loop — we verify no error on construction
      expect(agent).to be_a(described_class)
    end
  end

  describe "RubyPi::Agent.new convenience" do
    it "creates a Core instance" do
      a = RubyPi::Agent.new(system_prompt: "test", model: model)
      expect(a).to be_a(RubyPi::Agent::Core)
    end
  end
end
