# frozen_string_literal: true

# spec/ruby_pi/agent/state_spec.rb
#
# Tests for RubyPi::Agent::State — verifies message management, iteration
# tracking, hook storage, user_data, and max_iterations_reached? behavior.

require_relative "../../../lib/ruby_pi/agent/state"

RSpec.describe RubyPi::Agent::State do
  let(:model) { double("model") }
  let(:tools) { double("registry", size: 3) }

  let(:state) do
    described_class.new(
      system_prompt: "You are a helpful assistant.",
      model: model,
      tools: tools,
      max_iterations: 5
    )
  end

  describe "#initialize" do
    it "sets the system prompt" do
      expect(state.system_prompt).to eq("You are a helpful assistant.")
    end

    it "stores the model reference" do
      expect(state.model).to eq(model)
    end

    it "stores the tools registry" do
      expect(state.tools).to eq(tools)
    end

    it "defaults messages to an empty array" do
      expect(state.messages).to eq([])
    end

    it "defaults max_iterations to 10 when not specified" do
      default_state = described_class.new(
        system_prompt: "test",
        model: model
      )
      expect(default_state.max_iterations).to eq(10)
    end

    it "accepts initial messages" do
      initial = [{ role: :user, content: "Hello" }]
      s = described_class.new(system_prompt: "test", model: model, messages: initial)
      expect(s.messages).to eq(initial)
    end

    it "defaults iteration to 0" do
      expect(state.iteration).to eq(0)
    end

    it "defaults user_data to an empty hash" do
      expect(state.user_data).to eq({})
    end

    it "accepts user_data" do
      s = described_class.new(
        system_prompt: "test",
        model: model,
        user_data: { workspace: "test-ws" }
      )
      expect(s.user_data[:workspace]).to eq("test-ws")
    end
  end

  describe "#add_message" do
    it "adds a message to the history" do
      state.add_message(role: :user, content: "Hello")
      expect(state.messages.size).to eq(1)
      expect(state.messages.first[:role]).to eq(:user)
      expect(state.messages.first[:content]).to eq("Hello")
    end

    it "converts string roles to symbols" do
      state.add_message(role: "assistant", content: "Hi there")
      expect(state.messages.first[:role]).to eq(:assistant)
    end

    it "accepts additional options like tool_call_id" do
      state.add_message(role: :tool, content: '{"result": 42}', tool_call_id: "call_123", name: "my_tool")
      msg = state.messages.first
      expect(msg[:tool_call_id]).to eq("call_123")
      expect(msg[:name]).to eq("my_tool")
    end

    it "returns the updated messages array" do
      result = state.add_message(role: :user, content: "test")
      expect(result).to be_an(Array)
      expect(result.size).to eq(1)
    end
  end

  describe "#messages" do
    it "returns a frozen copy that cannot be mutated" do
      state.add_message(role: :user, content: "Hello")
      msgs = state.messages
      expect(msgs).to be_frozen
      expect { msgs << { role: :user, content: "world" } }.to raise_error(FrozenError)
    end

    it "does not expose internal array mutations" do
      state.add_message(role: :user, content: "first")
      msgs = state.messages
      state.add_message(role: :user, content: "second")
      expect(msgs.size).to eq(1) # frozen copy from before second add
      expect(state.messages.size).to eq(2)
    end
  end

  describe "#messages=" do
    it "replaces the message history" do
      state.add_message(role: :user, content: "old")
      state.messages = [{ role: :system, content: "summary" }]
      expect(state.messages.size).to eq(1)
      expect(state.messages.first[:role]).to eq(:system)
    end
  end

  describe "#iteration and #increment_iteration!" do
    it "starts at 0" do
      expect(state.iteration).to eq(0)
    end

    it "increments by 1 each call" do
      state.increment_iteration!
      expect(state.iteration).to eq(1)
      state.increment_iteration!
      expect(state.iteration).to eq(2)
    end

    it "returns the new count" do
      expect(state.increment_iteration!).to eq(1)
    end
  end

  describe "#max_iterations_reached?" do
    it "returns false when under the limit" do
      expect(state.max_iterations_reached?).to be false
    end

    it "returns true when at the limit" do
      5.times { state.increment_iteration! }
      expect(state.max_iterations_reached?).to be true
    end

    it "returns true when over the limit" do
      6.times { state.increment_iteration! }
      expect(state.max_iterations_reached?).to be true
    end
  end

  describe "hook callables" do
    it "stores and retrieves transform_context" do
      transform = ->(s) { s.system_prompt += " extra" }
      state.transform_context = transform
      expect(state.transform_context).to eq(transform)
    end

    it "stores and retrieves before_tool_call" do
      hook = ->(tc) { puts tc.name }
      state.before_tool_call = hook
      expect(state.before_tool_call).to eq(hook)
    end

    it "stores and retrieves after_tool_call" do
      hook = ->(tc, result) { puts result.success? }
      state.after_tool_call = hook
      expect(state.after_tool_call).to eq(hook)
    end

    it "defaults hooks to nil" do
      expect(state.transform_context).to be_nil
      expect(state.before_tool_call).to be_nil
      expect(state.after_tool_call).to be_nil
    end
  end

  describe "#system_prompt=" do
    it "allows mutating the system prompt" do
      state.system_prompt = "New prompt"
      expect(state.system_prompt).to eq("New prompt")
    end
  end

  describe "#inspect" do
    it "returns a readable summary" do
      expect(state.inspect).to include("RubyPi::Agent::State")
      expect(state.inspect).to include("iteration=0/5")
      expect(state.inspect).to include("messages=0")
      expect(state.inspect).to include("tools=3")
    end
  end
end
