# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_18_19_loop_error_handling_spec.rb
#
# Tests for Issues #18 and #19:
# - #18: Loop#run rescue swallows non-LLM exceptions
# - #19: max_iterations reports success?: true

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

RSpec.describe "Issues #18-#19: Loop error handling and max_iterations result" do
  let(:emitter) do
    obj = Object.new
    obj.extend(RubyPi::Agent::EventEmitter)
    obj
  end

  let(:model) { double("model") }
  let(:registry) { RubyPi::Tools::Registry.new }

  # Issue #18: Programming errors should be re-raised, not swallowed
  describe "Issue #18: Re-raise programming errors" do
    it "re-raises NoMethodError" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test", model: model, max_iterations: 5
      )
      state.add_message(role: :user, content: "test")

      allow(model).to receive(:complete).and_raise(NoMethodError, "undefined method 'foo'")

      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      expect { loop_runner.run }.to raise_error(NoMethodError, /foo/)
    end

    it "re-raises NameError" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test", model: model, max_iterations: 5
      )
      state.add_message(role: :user, content: "test")

      allow(model).to receive(:complete).and_raise(NameError, "uninitialized constant Bar")

      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      expect { loop_runner.run }.to raise_error(NameError, /Bar/)
    end

    it "re-raises ArgumentError" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test", model: model, max_iterations: 5
      )
      state.add_message(role: :user, content: "test")

      allow(model).to receive(:complete).and_raise(ArgumentError, "wrong number of arguments")

      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      expect { loop_runner.run }.to raise_error(ArgumentError, /wrong number/)
    end

    it "re-raises TypeError" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test", model: model, max_iterations: 5
      )
      state.add_message(role: :user, content: "test")

      allow(model).to receive(:complete).and_raise(TypeError, "no implicit conversion")

      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      expect { loop_runner.run }.to raise_error(TypeError, /no implicit/)
    end

    it "catches RuntimeError (non-programming error) in a Result" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test", model: model, max_iterations: 5
      )
      state.add_message(role: :user, content: "test")

      allow(model).to receive(:complete).and_raise(RuntimeError, "LLM failed")

      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      result = loop_runner.run

      expect(result.success?).to be false
      expect(result.error).to be_a(RuntimeError)
      expect(result.stop_reason).to eq(:error)
    end

    it "catches RubyPi::Error in a Result" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test", model: model, max_iterations: 5
      )
      state.add_message(role: :user, content: "test")

      allow(model).to receive(:complete).and_raise(RubyPi::ApiError.new("API broke"))

      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      result = loop_runner.run

      expect(result.success?).to be false
      expect(result.error).to be_a(RubyPi::ApiError)
    end
  end

  # Issue #19: max_iterations should not report success?: true
  describe "Issue #19: max_iterations result" do
    let(:limited_state) do
      RubyPi::Agent::State.new(
        system_prompt: "Test",
        model: model,
        tools: registry,
        max_iterations: 2
      )
    end

    before do
      tool = RubyPi::Tools::Definition.new(
        name: "loop_tool", description: "Loops"
      ) { |_| { status: "ok" } }
      registry.register(tool)

      limited_state.add_message(role: :user, content: "Loop forever")

      # Always return tool calls — never stop on its own
      allow(model).to receive(:complete) do |**_args, &_block|
        RubyPi::LLM::Response.new(
          content: nil,
          tool_calls: [RubyPi::LLM::ToolCall.new(id: "call_x", name: "loop_tool", arguments: {})],
          usage: {},
          finish_reason: "tool_calls"
        )
      end
    end

    it "returns success? = false when truncated by max_iterations" do
      loop_runner = RubyPi::Agent::Loop.new(state: limited_state, emitter: emitter)
      result = loop_runner.run

      expect(result.success?).to be false
      expect(result.stop_reason).to eq(:max_iterations)
    end

    it "returns truncated? = true when max_iterations reached" do
      loop_runner = RubyPi::Agent::Loop.new(state: limited_state, emitter: emitter)
      result = loop_runner.run

      expect(result.truncated?).to be true
    end

    it "returns truncated? = false for normal completion" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test", model: model, max_iterations: 10
      )
      state.add_message(role: :user, content: "test")

      allow(model).to receive(:complete).and_return(
        RubyPi::LLM::Response.new(content: "done", tool_calls: [], usage: {}, finish_reason: "stop")
      )

      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      result = loop_runner.run

      expect(result.truncated?).to be false
      expect(result.success?).to be true
      expect(result.stop_reason).to eq(:complete)
    end

    it "includes stop_reason in to_h" do
      loop_runner = RubyPi::Agent::Loop.new(state: limited_state, emitter: emitter)
      result = loop_runner.run
      hash = result.to_h

      expect(hash[:stop_reason]).to eq(:max_iterations)
      expect(hash[:truncated]).to be true
      expect(hash[:success]).to be false
    end
  end
end
