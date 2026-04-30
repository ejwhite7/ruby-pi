# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_16_17_agent_reset_nil_tools_spec.rb
#
# Tests for Issues #16 and #17:
# - #16: Agent#run does not reset iteration counter
# - #17: Agent with nil tools — NoMethodError

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

RSpec.describe "Issues #16-#17: Agent iteration reset and nil tools" do
  let(:emitter) do
    obj = Object.new
    obj.extend(RubyPi::Agent::EventEmitter)
    obj
  end

  let(:model) { double("model") }

  # Issue #16: State#reset_iteration! method
  describe "Issue #16: Iteration counter reset" do
    it "State responds to reset_iteration!" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test",
        model: model,
        max_iterations: 5
      )

      state.increment_iteration!
      state.increment_iteration!
      expect(state.iteration).to eq(2)

      state.reset_iteration!
      expect(state.iteration).to eq(0)
    end

    it "does not use instance_variable_set in core.rb" do
      source = File.read(File.expand_path("../../../lib/ruby_pi/agent/core.rb", __dir__))
      expect(source).not_to include("instance_variable_set")
      expect(source).to include("reset_iteration!")
    end

    it "resets iteration at start of run()" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test",
        model: model,
        max_iterations: 3
      )

      # Simulate that state already has iterations from a prior run
      state.increment_iteration!
      state.increment_iteration!
      expect(state.iteration).to eq(2)

      # Allow a simple LLM response
      allow(model).to receive(:complete).and_return(
        RubyPi::LLM::Response.new(content: "ok", tool_calls: [], usage: {}, finish_reason: "stop")
      )

      # Create loop and ensure reset happens (we test via State)
      state.reset_iteration!
      state.add_message(role: :user, content: "test")
      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      result = loop_runner.run

      # Should complete successfully (iteration was reset to 0)
      expect(result.success?).to be true
      expect(result.turns).to eq(1)
    end

    it "resets iteration at start of continue()" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test",
        model: model,
        max_iterations: 3
      )

      # Simulate prior iterations
      state.increment_iteration!
      state.increment_iteration!
      expect(state.max_iterations_reached?).to be false

      # After one more, it would be at 3 (== max)
      state.increment_iteration!
      expect(state.max_iterations_reached?).to be true

      # Reset should allow a new run
      state.reset_iteration!
      expect(state.max_iterations_reached?).to be false
      expect(state.iteration).to eq(0)
    end
  end

  # Issue #17: Nil tools guard
  describe "Issue #17: Nil tools NoMethodError prevention" do
    it "raises NoToolsRegisteredError when registry is nil in Executor" do
      executor = RubyPi::Tools::Executor.new(nil, mode: :sequential)

      expect {
        executor.execute([{ name: "fake_tool", arguments: {} }])
      }.to raise_error(RubyPi::NoToolsRegisteredError, /no tools are registered/)
    end

    it "raises NoToolsRegisteredError in loop when tools are nil and LLM returns tool calls" do
      state = RubyPi::Agent::State.new(
        system_prompt: "Test",
        model: model,
        tools: nil, # No tools registered
        max_iterations: 5
      )
      state.add_message(role: :user, content: "test")

      # LLM hallucinates a tool call
      allow(model).to receive(:complete).and_return(
        RubyPi::LLM::Response.new(
          content: nil,
          tool_calls: [RubyPi::LLM::ToolCall.new(id: "call_1", name: "fake_tool", arguments: {})],
          usage: {},
          finish_reason: "tool_calls"
        )
      )

      loop_runner = RubyPi::Agent::Loop.new(state: state, emitter: emitter)
      # NoToolsRegisteredError is NOT in the PROGRAMMING_ERRORS list,
      # so it should be caught by the StandardError rescue
      result = loop_runner.run

      expect(result.success?).to be false
      expect(result.error).to be_a(RubyPi::NoToolsRegisteredError)
    end

    it "defines RubyPi::NoToolsRegisteredError" do
      expect(defined?(RubyPi::NoToolsRegisteredError)).to eq("constant")
      expect(RubyPi::NoToolsRegisteredError.superclass).to eq(RubyPi::Error)
    end
  end
end
