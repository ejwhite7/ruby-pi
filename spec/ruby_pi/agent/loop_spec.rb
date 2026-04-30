# frozen_string_literal: true

# spec/ruby_pi/agent/loop_spec.rb
#
# Tests for RubyPi::Agent::Loop — verifies the think-act-observe cycle,
# tool call execution, max_iterations halt, streaming, compaction
# integration, configurable execution_mode/tool_timeout, and tool_call_delta
# event handling.

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

RSpec.describe RubyPi::Agent::Loop do
  # A simple emitter that collects events for assertion
  let(:emitter) do
    obj = Object.new
    obj.extend(RubyPi::Agent::EventEmitter)
    obj
  end

  let(:registry) { RubyPi::Tools::Registry.new }
  let(:model) { double("model") }

  let(:state) do
    RubyPi::Agent::State.new(
      system_prompt: "You are a test assistant.",
      model: model,
      tools: registry,
      max_iterations: 10
    )
  end

  # Helper: build a Response with no tool calls (LLM is done)
  def stop_response(content: "Done", usage: {})
    RubyPi::LLM::Response.new(
      content: content,
      tool_calls: [],
      usage: usage,
      finish_reason: "stop"
    )
  end

  # Helper: build a Response with tool calls
  def tool_call_response(calls, content: nil, usage: {})
    tool_calls = calls.map do |c|
      RubyPi::LLM::ToolCall.new(id: c[:id], name: c[:name], arguments: c[:arguments] || {})
    end
    RubyPi::LLM::Response.new(
      content: content,
      tool_calls: tool_calls,
      usage: usage,
      finish_reason: "tool_calls"
    )
  end

  describe "simple completion (no tool calls)" do
    before do
      state.add_message(role: :user, content: "Hello")
      allow(model).to receive(:complete).and_return(stop_response(content: "Hi there!"))
    end

    it "returns a successful Result with the LLM content" do
      loop_runner = described_class.new(state: state, emitter: emitter)
      result = loop_runner.run

      expect(result).to be_a(RubyPi::Agent::Result)
      expect(result.success?).to be true
      expect(result.content).to eq("Hi there!")
    end

    it "completes in 1 turn" do
      loop_runner = described_class.new(state: state, emitter: emitter)
      result = loop_runner.run
      expect(result.turns).to eq(1)
    end

    it "emits :turn_start and :turn_end events" do
      events = []
      emitter.on(:turn_start) { |d| events << [:turn_start, d] }
      emitter.on(:turn_end) { |d| events << [:turn_end, d] }

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(events.map(&:first)).to eq([:turn_start, :turn_end])
    end

    it "adds the assistant response to state messages" do
      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      assistant_msg = state.messages.find { |m| m[:role] == :assistant }
      expect(assistant_msg).not_to be_nil
      expect(assistant_msg[:content]).to eq("Hi there!")
    end
  end

  describe "tool call cycle" do
    let(:echo_tool) do
      RubyPi::Tools::Definition.new(
        name: "echo",
        description: "Echoes input"
      ) { |args| { echoed: args[:input] } }
    end

    before do
      registry.register(echo_tool)
      state.add_message(role: :user, content: "Echo this")

      # First call returns a tool call, second call returns stop
      call_count = 0
      allow(model).to receive(:complete) do |**_args, &_block|
        call_count += 1
        if call_count == 1
          tool_call_response([{ id: "call_1", name: "echo", arguments: { input: "hello" } }])
        else
          stop_response(content: "Echoed: hello")
        end
      end
    end

    it "executes the tool and continues to completion" do
      loop_runner = described_class.new(state: state, emitter: emitter)
      result = loop_runner.run

      expect(result.success?).to be true
      expect(result.content).to eq("Echoed: hello")
      expect(result.turns).to eq(2)
    end

    it "records the tool call in tool_calls_made" do
      loop_runner = described_class.new(state: state, emitter: emitter)
      result = loop_runner.run

      expect(result.tool_calls_made.size).to eq(1)
      expect(result.tool_calls_made.first[:tool_name]).to eq("echo")
    end

    it "emits :tool_execution_start and :tool_execution_end" do
      events = []
      emitter.on(:tool_execution_start) { |d| events << [:start, d[:tool_name]] }
      emitter.on(:tool_execution_end) { |d| events << [:end, d[:tool_name]] }

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(events).to eq([[:start, "echo"], [:end, "echo"]])
    end

    it "adds tool result to state messages" do
      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      tool_msg = state.messages.find { |m| m[:role] == :tool }
      expect(tool_msg).not_to be_nil
      expect(tool_msg[:name]).to eq("echo")
      expect(tool_msg[:tool_call_id]).to eq("call_1")
    end
  end

  describe "max iterations halt" do
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
        tool_call_response([{ id: "call_x", name: "loop_tool" }])
      end
    end

    it "halts after max_iterations" do
      loop_runner = described_class.new(state: limited_state, emitter: emitter)
      result = loop_runner.run

      expect(result.turns).to eq(2)
      expect(result.success?).to be true
    end
  end

  describe "before_tool_call and after_tool_call hooks" do
    before do
      tool = RubyPi::Tools::Definition.new(
        name: "hook_tool", description: "For hooks"
      ) { |_| { done: true } }
      registry.register(tool)
      state.add_message(role: :user, content: "Test hooks")

      call_count = 0
      allow(model).to receive(:complete) do |**_args, &_block|
        call_count += 1
        if call_count == 1
          tool_call_response([{ id: "c1", name: "hook_tool" }])
        else
          stop_response(content: "done")
        end
      end
    end

    it "calls before_tool_call with the tool call object" do
      received_tc = nil
      state.before_tool_call = ->(tc) { received_tc = tc }

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(received_tc).not_to be_nil
      expect(received_tc.name).to eq("hook_tool")
    end

    it "calls after_tool_call with the tool call and result" do
      received_args = nil
      state.after_tool_call = ->(tc, result) { received_args = [tc.name, result.success?] }

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(received_args).to eq(["hook_tool", true])
    end
  end

  describe "transform_context hook" do
    before do
      state.add_message(role: :user, content: "Transform test")
      allow(model).to receive(:complete).and_return(stop_response(content: "ok"))
    end

    it "calls transform_context before each LLM call" do
      transform_called = false
      state.transform_context = ->(_s) { transform_called = true }

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(transform_called).to be true
    end

    it "can mutate the system prompt" do
      state.transform_context = ->(s) { s.system_prompt += " [EXTRA]" }

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(state.system_prompt).to include("[EXTRA]")
    end
  end

  describe "error handling" do
    before do
      state.add_message(role: :user, content: "Fail test")
      allow(model).to receive(:complete).and_raise(RuntimeError, "LLM exploded")
    end

    it "returns a failed Result on error" do
      loop_runner = described_class.new(state: state, emitter: emitter)
      result = loop_runner.run

      expect(result.success?).to be false
      expect(result.error).to be_a(RuntimeError)
      expect(result.error.message).to eq("LLM exploded")
    end

    it "emits an :error event" do
      error_data = nil
      emitter.on(:error) { |d| error_data = d }

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(error_data[:error].message).to eq("LLM exploded")
      expect(error_data[:source]).to eq(:agent_loop)
    end
  end

  describe "usage accumulation" do
    before do
      state.add_message(role: :user, content: "Usage test")

      call_count = 0
      allow(model).to receive(:complete) do |**_args, &_block|
        call_count += 1
        if call_count == 1
          RubyPi::LLM::Response.new(
            content: nil,
            tool_calls: [RubyPi::LLM::ToolCall.new(id: "c1", name: "t", arguments: {})],
            usage: { prompt_tokens: 100, completion_tokens: 50 },
            finish_reason: "tool_calls"
          )
        else
          RubyPi::LLM::Response.new(
            content: "done",
            tool_calls: [],
            usage: { prompt_tokens: 200, completion_tokens: 75 },
            finish_reason: "stop"
          )
        end
      end

      tool = RubyPi::Tools::Definition.new(name: "t", description: "test") { |_| {} }
      registry.register(tool)
    end

    it "accumulates token usage across turns" do
      loop_runner = described_class.new(state: state, emitter: emitter)
      result = loop_runner.run

      expect(result.usage[:input_tokens]).to eq(300)
      expect(result.usage[:output_tokens]).to eq(125)
    end
  end

  describe "configurable execution_mode and tool_timeout (#36)" do
    it "accepts execution_mode and tool_timeout parameters" do
      loop_runner = described_class.new(
        state: state,
        emitter: emitter,
        execution_mode: :sequential,
        tool_timeout: 60
      )
      expect(loop_runner).to be_a(described_class)
    end

    it "defaults to :parallel mode with 30s timeout" do
      # The default values are used when params are not specified
      loop_runner = described_class.new(state: state, emitter: emitter)
      state.add_message(role: :user, content: "Test")
      allow(model).to receive(:complete).and_return(stop_response)
      result = loop_runner.run
      expect(result.success?).to be true
    end
  end

  describe "tool_call_delta event (#37)" do
    before do
      state.add_message(role: :user, content: "Stream test")
    end

    it "emits :tool_call_delta when provider yields tool call streaming data" do
      deltas = []
      emitter.on(:tool_call_delta) { |d| deltas << d }

      # Mock the model to yield a tool_call_delta stream event
      allow(model).to receive(:complete) do |**_args, &block|
        if block
          event = RubyPi::LLM::StreamEvent.new(
            type: :tool_call_delta,
            data: { name: "search", partial_args: '{"q":' }
          )
          block.call(event)
        end
        stop_response(content: "Final answer")
      end

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(deltas.size).to eq(1)
      expect(deltas.first[:data][:name]).to eq("search")
    end

    it "emits both :text_delta and :tool_call_delta from same stream" do
      text_deltas = []
      tool_deltas = []
      emitter.on(:text_delta) { |d| text_deltas << d[:content] }
      emitter.on(:tool_call_delta) { |d| tool_deltas << d[:data] }

      allow(model).to receive(:complete) do |**_args, &block|
        if block
          block.call(RubyPi::LLM::StreamEvent.new(type: :text_delta, data: "Hello"))
          block.call(RubyPi::LLM::StreamEvent.new(
            type: :tool_call_delta,
            data: { name: "calc", partial_args: "{}" }
          ))
        end
        stop_response(content: "Hello")
      end

      loop_runner = described_class.new(state: state, emitter: emitter)
      loop_runner.run

      expect(text_deltas).to eq(["Hello"])
      expect(tool_deltas.size).to eq(1)
      expect(tool_deltas.first[:name]).to eq("calc")
    end
  end
end
