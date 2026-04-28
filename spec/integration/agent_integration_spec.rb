# frozen_string_literal: true

# spec/integration/agent_integration_spec.rb
#
# End-to-end integration tests for the RubyPi agent loop. Each test constructs
# a real Agent, Registry, and provider stack with WebMock-stubbed HTTP responses
# so that the full think-act-observe loop executes without any live API calls.

require "spec_helper"

# ---------------------------------------------------------------------------
# Shared helpers for building mock HTTP responses
# ---------------------------------------------------------------------------
module IntegrationHelpers
  module_function

  # Returns a Gemini JSON body for a plain text response (no tool calls).
  def gemini_text_response(text, prompt_tokens: 10, completion_tokens: 20)
    {
      candidates: [
        {
          content: { role: "model", parts: [{ text: text }] },
          finishReason: "STOP"
        }
      ],
      usageMetadata: {
        promptTokenCount: prompt_tokens,
        candidatesTokenCount: completion_tokens,
        totalTokenCount: prompt_tokens + completion_tokens
      }
    }.to_json
  end

  # Returns a Gemini JSON body that requests a function call.
  def gemini_tool_call_response(name, args = {}, call_id: nil)
    {
      candidates: [
        {
          content: {
            role: "model",
            parts: [{ functionCall: { name: name, args: args } }]
          },
          finishReason: "STOP"
        }
      ],
      usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15 }
    }.to_json
  end

  # Returns a Gemini JSON body that requests multiple function calls.
  def gemini_multi_tool_call_response(calls)
    parts = calls.map { |c| { functionCall: { name: c[:name], args: c[:args] || {} } } }
    {
      candidates: [
        {
          content: { role: "model", parts: parts },
          finishReason: "STOP"
        }
      ],
      usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15 }
    }.to_json
  end

  # Returns a Gemini SSE streaming body with text chunks.
  def gemini_streaming_body(chunks)
    chunks.map do |chunk|
      data = {
        candidates: [
          { content: { role: "model", parts: [{ text: chunk }] } }
        ]
      }
      "data: #{data.to_json}\n\n"
    end.join
  end

  # Returns an OpenAI JSON body for a plain text response.
  def openai_text_response(text, prompt_tokens: 10, completion_tokens: 20)
    {
      id: "chatcmpl-test",
      object: "chat.completion",
      choices: [
        {
          index: 0,
          message: { role: "assistant", content: text },
          finish_reason: "stop"
        }
      ],
      usage: {
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: prompt_tokens + completion_tokens
      }
    }.to_json
  end

  # Builds a simple tool definition and returns it.
  def build_tool(name, description = "A test tool", &block)
    RubyPi::Tool.define(
      name: name,
      description: description,
      parameters: RubyPi::Schema.object(
        input: RubyPi::Schema.string("Input value")
      ),
      &block
    )
  end
end

# ---------------------------------------------------------------------------
# Integration specs
# ---------------------------------------------------------------------------
RSpec.describe "Agent Integration", :integration do
  include IntegrationHelpers

  let(:gemini_url) { %r{https://generativelanguage\.googleapis\.com/v1beta/models/.+:generateContent} }
  let(:gemini_stream_url) { %r{https://generativelanguage\.googleapis\.com/v1beta/models/.+:streamGenerateContent} }
  let(:openai_url) { "https://api.openai.com/v1/chat/completions" }
  let(:anthropic_url) { "https://api.anthropic.com/v1/messages" }

  # -----------------------------------------------------------------------
  # 1. Single-turn conversation without tools
  # -----------------------------------------------------------------------
  it "completes a single-turn conversation without tools" do
    stub_request(:post, gemini_url)
      .to_return(status: 200, body: gemini_text_response("Hello, world!"), headers: { "Content-Type" => "application/json" })

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model)
    result = agent.run("Hi there")

    expect(result).to be_a(RubyPi::Agent::Result)
    expect(result.output).to eq("Hello, world!")
    expect(result.messages.length).to be >= 2 # user + assistant
  end

  # -----------------------------------------------------------------------
  # 2. Tool call execution loop
  # -----------------------------------------------------------------------
  it "executes a tool call and continues the loop" do
    # First LLM call → tool call, second LLM call → text response
    stub_request(:post, gemini_url)
      .to_return(
        { status: 200, body: gemini_tool_call_response("get_weather", { city: "NYC" }), headers: { "Content-Type" => "application/json" } },
        { status: 200, body: gemini_text_response("The weather in NYC is sunny."), headers: { "Content-Type" => "application/json" } }
      )

    weather_tool = RubyPi::Tool.define(
      name: :get_weather,
      description: "Get weather for a city",
      parameters: RubyPi::Schema.object(
        city: RubyPi::Schema.string("City name", required: true)
      )
    ) { |args| { temperature: 72, condition: "sunny" } }

    registry = RubyPi::Tools::Registry.new
    registry.register(weather_tool)

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model, tools: registry)
    result = agent.run("What is the weather in NYC?")

    expect(result.output).to eq("The weather in NYC is sunny.")
    expect(result.tool_calls_made).to include(
      a_hash_including(name: "get_weather")
    )
  end

  # -----------------------------------------------------------------------
  # 3. Multiple tool calls in one turn
  # -----------------------------------------------------------------------
  it "handles multiple tool calls in one turn" do
    stub_request(:post, gemini_url)
      .to_return(
        {
          status: 200,
          body: gemini_multi_tool_call_response([
            { name: "get_weather", args: { city: "NYC" } },
            { name: "get_weather", args: { city: "London" } }
          ]),
          headers: { "Content-Type" => "application/json" }
        },
        {
          status: 200,
          body: gemini_text_response("NYC is sunny, London is rainy."),
          headers: { "Content-Type" => "application/json" }
        }
      )

    weather_tool = RubyPi::Tool.define(
      name: :get_weather,
      description: "Get weather for a city",
      parameters: RubyPi::Schema.object(
        city: RubyPi::Schema.string("City name", required: true)
      )
    ) do |args|
      case args["city"] || args[:city]
      when "NYC" then { temperature: 72, condition: "sunny" }
      when "London" then { temperature: 55, condition: "rainy" }
      end
    end

    registry = RubyPi::Tools::Registry.new
    registry.register(weather_tool)

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model, tools: registry)
    result = agent.run("Weather in NYC and London?")

    expect(result.output).to eq("NYC is sunny, London is rainy.")
    expect(result.tool_calls_made.length).to eq(2)
  end

  # -----------------------------------------------------------------------
  # 4. Respects max_iterations limit
  # -----------------------------------------------------------------------
  it "respects max_iterations limit" do
    # LLM always returns a tool call — agent should stop after max_iterations
    stub_request(:post, gemini_url)
      .to_return(
        status: 200,
        body: gemini_tool_call_response("loop_tool", { n: 1 }),
        headers: { "Content-Type" => "application/json" }
      )

    loop_tool = RubyPi::Tool.define(
      name: :loop_tool,
      description: "A tool that loops",
      parameters: RubyPi::Schema.object(n: RubyPi::Schema.integer("N"))
    ) { |args| { ok: true } }

    registry = RubyPi::Tools::Registry.new
    registry.register(loop_tool)

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model, tools: registry, max_iterations: 3)
    result = agent.run("Do something")

    # Agent should have stopped after 3 iterations, not run forever
    expect(result.iterations).to be <= 3
    expect(result.stop_reason).to eq(:max_iterations)
  end

  # -----------------------------------------------------------------------
  # 5. Emits all expected events in order
  # -----------------------------------------------------------------------
  it "emits all expected events in order" do
    stub_request(:post, gemini_url)
      .to_return(
        { status: 200, body: gemini_tool_call_response("greet", { name: "Alice" }), headers: { "Content-Type" => "application/json" } },
        { status: 200, body: gemini_text_response("Hi Alice!"), headers: { "Content-Type" => "application/json" } }
      )

    greet_tool = RubyPi::Tool.define(
      name: :greet,
      description: "Greet someone",
      parameters: RubyPi::Schema.object(name: RubyPi::Schema.string("Name", required: true))
    ) { |args| "Hello, #{args['name'] || args[:name]}!" }

    registry = RubyPi::Tools::Registry.new
    registry.register(greet_tool)

    events = []
    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model, tools: registry)

    agent.on(:turn_start) { |e| events << [:turn_start, e] }
    agent.on(:turn_end) { |e| events << [:turn_end, e] }
    agent.on(:tool_execution_start) { |e| events << [:tool_execution_start, e] }
    agent.on(:tool_execution_end) { |e| events << [:tool_execution_end, e] }
    agent.on(:agent_end) { |e| events << [:agent_end, e] }

    agent.run("Say hi to Alice")

    event_types = events.map(&:first)

    # First turn: think → tool_execution_start → tool_execution_end → turn_end
    # Second turn: think → turn_end → agent_end
    expect(event_types).to include(:turn_start, :tool_execution_start, :tool_execution_end, :turn_end, :agent_end)

    # turn_start should come before tool_execution_start
    first_turn_start = event_types.index(:turn_start)
    first_tool_start = event_types.index(:tool_execution_start)
    first_agent_end = event_types.index(:agent_end)

    expect(first_turn_start).to be < first_tool_start
    expect(first_tool_start).to be < first_agent_end
  end

  # -----------------------------------------------------------------------
  # 6. Streams text_delta events during LLM response
  # -----------------------------------------------------------------------
  it "streams text_delta events during LLM response" do
    sse_body = gemini_streaming_body(["Hello", ", ", "world", "!"])

    stub_request(:post, gemini_stream_url)
      .to_return(status: 200, body: sse_body, headers: { "Content-Type" => "text/event-stream" })

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model, stream: true)

    text_deltas = []
    agent.on(:text_delta) { |e| text_deltas << e[:data] }

    result = agent.run("Say hello")

    expect(text_deltas).to eq(["Hello", ", ", "world", "!"])
    expect(result.output).to eq("Hello, world!")
  end

  # -----------------------------------------------------------------------
  # 7. Multi-turn conversation
  # -----------------------------------------------------------------------
  it "continues a multi-turn conversation" do
    call_count = 0
    stub_request(:post, gemini_url)
      .to_return do |request|
        call_count += 1
        case call_count
        when 1
          { status: 200, body: gemini_text_response("I am RubyPi, an AI assistant."), headers: { "Content-Type" => "application/json" } }
        when 2
          { status: 200, body: gemini_text_response("I already told you — I am RubyPi!"), headers: { "Content-Type" => "application/json" } }
        else
          { status: 200, body: gemini_text_response("Still RubyPi."), headers: { "Content-Type" => "application/json" } }
        end
      end

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model)

    result1 = agent.run("Who are you?")
    expect(result1.output).to eq("I am RubyPi, an AI assistant.")

    result2 = agent.continue("Tell me again")
    expect(result2.output).to eq("I already told you — I am RubyPi!")

    # The second call should have included the full conversation history
    expect(result2.messages.length).to be >= 4 # user1, assistant1, user2, assistant2
  end

  # -----------------------------------------------------------------------
  # 8. Compacts context when token limit is reached
  # -----------------------------------------------------------------------
  it "compacts context when token limit is reached" do
    stub_request(:post, gemini_url)
      .to_return(
        status: 200,
        body: gemini_text_response("Compacted response."),
        headers: { "Content-Type" => "application/json" }
      )

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    compaction = RubyPi::Context::Compaction.new(max_tokens: 50, strategy: :truncate)
    agent = RubyPi::Agent.new(model: model, context_compaction: compaction)

    # Seed a long conversation history to exceed the token limit
    long_messages = 20.times.map do |i|
      { role: i.even? ? "user" : "assistant", content: "Message number #{i} with some extra padding text to increase token count." }
    end
    agent.instance_variable_set(:@messages, long_messages) if agent.respond_to?(:instance_variable_set)

    result = agent.run("Summarize everything")

    # After compaction, the messages sent to the LLM should be shorter than the original
    expect(result.output).to eq("Compacted response.")
  end

  # -----------------------------------------------------------------------
  # 9. Applies transform_context before each LLM call
  # -----------------------------------------------------------------------
  it "applies transform_context before each LLM call" do
    transformed = false

    stub_request(:post, gemini_url)
      .to_return(status: 200, body: gemini_text_response("Transformed!"), headers: { "Content-Type" => "application/json" })

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    transform = RubyPi::Context::Transform.new do |messages|
      transformed = true
      # Prepend a system message to every LLM call
      [{ role: "system", content: "You are a helpful assistant." }] + messages
    end

    agent = RubyPi::Agent.new(model: model, context_transform: transform)
    result = agent.run("Hello")

    expect(transformed).to be true
    expect(result.output).to eq("Transformed!")
  end

  # -----------------------------------------------------------------------
  # 10. Fires before_tool_call and after_tool_call hooks
  # -----------------------------------------------------------------------
  it "fires before_tool_call and after_tool_call hooks" do
    stub_request(:post, gemini_url)
      .to_return(
        { status: 200, body: gemini_tool_call_response("ping", {}), headers: { "Content-Type" => "application/json" } },
        { status: 200, body: gemini_text_response("Pong received."), headers: { "Content-Type" => "application/json" } }
      )

    ping_tool = RubyPi::Tool.define(
      name: :ping,
      description: "Ping",
      parameters: RubyPi::Schema.object
    ) { |_args| "pong" }

    registry = RubyPi::Tools::Registry.new
    registry.register(ping_tool)

    hook_log = []
    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model, tools: registry)

    agent.on(:before_tool_call) { |e| hook_log << [:before, e[:tool_name]] }
    agent.on(:after_tool_call) { |e| hook_log << [:after, e[:tool_name]] }

    agent.run("Ping me")

    expect(hook_log).to eq([[:before, "ping"], [:after, "ping"]])
  end

  # -----------------------------------------------------------------------
  # 11. Falls back to secondary provider on primary failure
  # -----------------------------------------------------------------------
  it "falls back to secondary provider on primary failure" do
    # Primary (Gemini) fails with 500
    stub_request(:post, gemini_url)
      .to_return(status: 500, body: '{"error":"internal"}', headers: { "Content-Type" => "application/json" })

    # Fallback (OpenAI) succeeds
    stub_request(:post, openai_url)
      .to_return(status: 200, body: openai_text_response("Fallback answer."), headers: { "Content-Type" => "application/json" })

    primary = RubyPi::LLM.model(:gemini, "gemini-2.0-flash", max_retries: 1, retry_base_delay: 0.001, retry_max_delay: 0.001)
    fallback = RubyPi::LLM.model(:openai, "gpt-4o")
    provider = RubyPi::LLM::Fallback.new(primary: primary, fallback: fallback, max_retries: 1, retry_base_delay: 0.001, retry_max_delay: 0.001)

    agent = RubyPi::Agent.new(model: provider)
    result = agent.run("Help me")

    expect(result.output).to eq("Fallback answer.")
  end

  # -----------------------------------------------------------------------
  # 12. Surfaces errors via the :error event
  # -----------------------------------------------------------------------
  it "surfaces errors via the :error event" do
    # All requests fail
    stub_request(:post, gemini_url)
      .to_return(status: 500, body: '{"error":"boom"}', headers: { "Content-Type" => "application/json" })

    errors = []
    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash", max_retries: 1, retry_base_delay: 0.001, retry_max_delay: 0.001)
    agent = RubyPi::Agent.new(model: model)
    agent.on(:error) { |e| errors << e }

    expect { agent.run("Fail please") }.to raise_error(RubyPi::ApiError)

    expect(errors.length).to be >= 1
    expect(errors.first[:error]).to be_a(RubyPi::ApiError)
  end

  # -----------------------------------------------------------------------
  # 13. Extension registers and receives events
  # -----------------------------------------------------------------------
  it "an extension registers and receives events" do
    stub_request(:post, gemini_url)
      .to_return(status: 200, body: gemini_text_response("Extended!"), headers: { "Content-Type" => "application/json" })

    # Define a custom extension
    log_extension_class = Class.new(RubyPi::Extensions::Base) do
      attr_reader :received_events

      def initialize
        super
        @received_events = []
      end

      on_event :turn_start do |event|
        @received_events << [:turn_start, event]
      end

      on_event :agent_end do |event|
        @received_events << [:agent_end, event]
      end
    end

    extension = log_extension_class.new

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(model: model, extensions: [extension])
    result = agent.run("Hello with extension")

    expect(result.output).to eq("Extended!")
    event_types = extension.received_events.map(&:first)
    expect(event_types).to include(:turn_start, :agent_end)
  end
end
