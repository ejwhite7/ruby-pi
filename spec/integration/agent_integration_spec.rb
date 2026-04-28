# frozen_string_literal: true

# spec/integration/agent_integration_spec.rb
#
# End-to-end integration tests for the RubyPi agent loop. Each test constructs
# a real Agent, Registry, and provider stack with WebMock-stubbed HTTP responses
# so that the full think-act-observe loop executes without any live API calls.
#
# Note: the agent loop always calls the LLM with stream: true and a block, so
# Gemini requests hit the SSE streamGenerateContent endpoint. All Gemini stubs
# below therefore return SSE-formatted bodies. The OpenAI provider is hit only
# in the fallback test, also via streaming.

require "spec_helper"

# ---------------------------------------------------------------------------
# Shared helpers for building mock HTTP responses
# ---------------------------------------------------------------------------
module IntegrationHelpers
  module_function

  # Wraps a Gemini payload as a single SSE event.
  def gemini_sse_event(payload)
    "data: #{payload.to_json}\n\n"
  end

  # SSE body for a plain text Gemini response.
  def gemini_text_response(text, prompt_tokens: 10, completion_tokens: 20)
    gemini_sse_event(
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
    )
  end

  # Standard (non-streaming) Gemini JSON response. Used by the Compaction
  # summary model, which calls complete(stream: false).
  def gemini_text_response_json(text, prompt_tokens: 10, completion_tokens: 20)
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

  # SSE body for a Gemini response that requests a single function call.
  def gemini_tool_call_response(name, args = {})
    gemini_sse_event(
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
    )
  end

  # SSE body for a Gemini response that requests multiple function calls.
  def gemini_multi_tool_call_response(calls)
    parts = calls.map { |c| { functionCall: { name: c[:name], args: c[:args] || {} } } }
    gemini_sse_event(
      candidates: [
        {
          content: { role: "model", parts: parts },
          finishReason: "STOP"
        }
      ],
      usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15 }
    )
  end

  # Multi-chunk Gemini SSE body for streaming-delta tests.
  def gemini_streaming_body(chunks)
    chunks.map do |chunk|
      gemini_sse_event(
        candidates: [{ content: { role: "model", parts: [{ text: chunk }] } }]
      )
    end.join
  end

  # SSE body for an OpenAI chat completion response.
  def openai_streaming_response(text, finish_reason: "stop")
    [
      { id: "chatcmpl-test", object: "chat.completion.chunk",
        choices: [{ index: 0, delta: { role: "assistant", content: text } }] },
      { id: "chatcmpl-test", object: "chat.completion.chunk",
        choices: [{ index: 0, delta: {}, finish_reason: finish_reason }] }
    ].map { |c| "data: #{c.to_json}\n\n" }.join + "data: [DONE]\n\n"
  end
end

# ---------------------------------------------------------------------------
# Integration specs
# ---------------------------------------------------------------------------
RSpec.describe "Agent Integration", :integration do
  include IntegrationHelpers

  # The agent loop always streams, so Gemini requests hit streamGenerateContent.
  let(:gemini_stream_url) do
    %r{https://generativelanguage\.googleapis\.com/v1beta/models/.+:streamGenerateContent}
  end
  # Used by Compaction's summary model (stream: false).
  let(:gemini_standard_url) do
    %r{https://generativelanguage\.googleapis\.com/v1beta/models/.+:generateContent}
  end
  let(:openai_url) { "https://api.openai.com/v1/chat/completions" }
  let(:default_system) { "You are a test assistant." }

  let(:sse_headers) { { "Content-Type" => "text/event-stream" } }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  # -----------------------------------------------------------------------
  # 1. Single-turn conversation without tools
  # -----------------------------------------------------------------------
  it "completes a single-turn conversation without tools" do
    stub_request(:post, gemini_stream_url)
      .to_return(status: 200, body: gemini_text_response("Hello, world!"), headers: sse_headers)

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model)
    result = agent.run("Hi there")

    expect(result).to be_a(RubyPi::Agent::Result)
    expect(result).to be_success
    expect(result.content).to eq("Hello, world!")
    expect(result.messages.length).to be >= 2 # user + assistant
  end

  # -----------------------------------------------------------------------
  # 2. Tool call execution loop
  # -----------------------------------------------------------------------
  it "executes a tool call and continues the loop" do
    stub_request(:post, gemini_stream_url)
      .to_return(
        { status: 200, body: gemini_tool_call_response("get_weather", { city: "NYC" }), headers: sse_headers },
        { status: 200, body: gemini_text_response("The weather in NYC is sunny."), headers: sse_headers }
      )

    weather_tool = RubyPi::Tool.define(
      name: "get_weather",
      description: "Get weather for a city",
      parameters: RubyPi::Schema.object(
        city: RubyPi::Schema.string("City name", required: true)
      )
    ) { |_args| { temperature: 72, condition: "sunny" } }

    registry = RubyPi::Tools::Registry.new
    registry.register(weather_tool)

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model, tools: registry)
    result = agent.run("What is the weather in NYC?")

    expect(result.content).to eq("The weather in NYC is sunny.")
    expect(result.tool_calls_made).to include(a_hash_including(tool_name: "get_weather"))
  end

  # -----------------------------------------------------------------------
  # 3. Multiple tool calls in one turn
  # -----------------------------------------------------------------------
  it "handles multiple tool calls in one turn" do
    stub_request(:post, gemini_stream_url)
      .to_return(
        {
          status: 200,
          body: gemini_multi_tool_call_response([
            { name: "get_weather", args: { city: "NYC" } },
            { name: "get_weather", args: { city: "London" } }
          ]),
          headers: sse_headers
        },
        { status: 200, body: gemini_text_response("NYC is sunny, London is rainy."), headers: sse_headers }
      )

    weather_tool = RubyPi::Tool.define(
      name: "get_weather",
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
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model, tools: registry)
    result = agent.run("Weather in NYC and London?")

    expect(result.content).to eq("NYC is sunny, London is rainy.")
    expect(result.tool_calls_made.length).to eq(2)
  end

  # -----------------------------------------------------------------------
  # 4. Respects max_iterations limit
  # -----------------------------------------------------------------------
  it "respects max_iterations limit" do
    # LLM always returns a tool call — agent should halt at max_iterations.
    stub_request(:post, gemini_stream_url)
      .to_return(
        status: 200,
        body: gemini_tool_call_response("loop_tool", { n: 1 }),
        headers: sse_headers
      )

    loop_tool = RubyPi::Tool.define(
      name: "loop_tool",
      description: "A tool that loops",
      parameters: RubyPi::Schema.object(n: RubyPi::Schema.integer("N"))
    ) { |_args| { ok: true } }

    registry = RubyPi::Tools::Registry.new
    registry.register(loop_tool)

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(
      system_prompt: default_system,
      model: model,
      tools: registry,
      max_iterations: 3
    )
    result = agent.run("Do something")

    expect(result.turns).to eq(3)
    expect(result).to be_success
  end

  # -----------------------------------------------------------------------
  # 5. Emits all expected events in order
  # -----------------------------------------------------------------------
  it "emits all expected events in order" do
    stub_request(:post, gemini_stream_url)
      .to_return(
        { status: 200, body: gemini_tool_call_response("greet", { name: "Alice" }), headers: sse_headers },
        { status: 200, body: gemini_text_response("Hi Alice!"), headers: sse_headers }
      )

    greet_tool = RubyPi::Tool.define(
      name: "greet",
      description: "Greet someone",
      parameters: RubyPi::Schema.object(name: RubyPi::Schema.string("Name", required: true))
    ) { |args| "Hello, #{args['name'] || args[:name]}!" }

    registry = RubyPi::Tools::Registry.new
    registry.register(greet_tool)

    events = []
    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model, tools: registry)

    agent.on(:turn_start) { |e| events << [:turn_start, e] }
    agent.on(:turn_end) { |e| events << [:turn_end, e] }
    agent.on(:tool_execution_start) { |e| events << [:tool_execution_start, e] }
    agent.on(:tool_execution_end) { |e| events << [:tool_execution_end, e] }
    agent.on(:agent_end) { |e| events << [:agent_end, e] }

    agent.run("Say hi to Alice")

    event_types = events.map(&:first)

    # We expect: turn_start (turn 1) → tool_execution_start → tool_execution_end
    #            → turn_end (turn 1) → turn_start (turn 2) → turn_end (turn 2)
    #            → agent_end
    expect(event_types).to include(:turn_start, :tool_execution_start, :tool_execution_end, :turn_end, :agent_end)

    expect(event_types.index(:turn_start)).to be < event_types.index(:tool_execution_start)
    expect(event_types.index(:tool_execution_start)).to be < event_types.index(:tool_execution_end)
    expect(event_types.index(:tool_execution_end)).to be < event_types.index(:agent_end)
    expect(event_types.last).to eq(:agent_end)
  end

  # -----------------------------------------------------------------------
  # 6. Streams text_delta events during LLM response
  # -----------------------------------------------------------------------
  it "streams text_delta events during LLM response" do
    sse_body = gemini_streaming_body(["Hello", ", ", "world", "!"])

    stub_request(:post, gemini_stream_url)
      .to_return(status: 200, body: sse_body, headers: sse_headers)

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model)

    text_deltas = []
    agent.on(:text_delta) { |e| text_deltas << e[:content] }

    result = agent.run("Say hello")

    expect(text_deltas).to eq(["Hello", ", ", "world", "!"])
    expect(result.content).to eq("Hello, world!")
  end

  # -----------------------------------------------------------------------
  # 7. Multi-turn conversation
  # -----------------------------------------------------------------------
  it "continues a multi-turn conversation" do
    call_count = 0
    stub_request(:post, gemini_stream_url).to_return do |_request|
      call_count += 1
      body = case call_count
             when 1 then gemini_text_response("I am RubyPi, an AI assistant.")
             when 2 then gemini_text_response("I already told you - I am RubyPi!")
             else        gemini_text_response("Still RubyPi.")
             end
      { status: 200, body: body, headers: { "Content-Type" => "text/event-stream" } }
    end

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model)

    result1 = agent.run("Who are you?")
    expect(result1.content).to eq("I am RubyPi, an AI assistant.")

    result2 = agent.continue("Tell me again")
    expect(result2.content).to eq("I already told you - I am RubyPi!")

    # The continuation should have at least: user1, assistant1, user2, assistant2
    expect(result2.messages.length).to be >= 4
  end

  # -----------------------------------------------------------------------
  # 8. Compacts context when token limit is reached
  # -----------------------------------------------------------------------
  it "compacts context when token limit is reached" do
    # Compaction's summary model uses stream: false (standard endpoint).
    stub_request(:post, gemini_standard_url)
      .to_return(status: 200, body: gemini_text_response_json("Summary of older messages."), headers: json_headers)

    # The agent loop's think call hits the streaming endpoint.
    stub_request(:post, gemini_stream_url)
      .to_return(status: 200, body: gemini_text_response("Compacted response."), headers: sse_headers)

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    summary_model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    compaction = RubyPi::Context::Compaction.new(
      max_tokens: 50,
      summary_model: summary_model,
      preserve_last_n: 2
    )
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model, compaction: compaction)

    # Seed long conversation history directly on state — exceeds the 50-token budget
    # so compaction will trigger before the first think call.
    long_messages = 20.times.map do |i|
      {
        role: i.even? ? :user : :assistant,
        content: "Message number #{i} with some extra padding text to increase token count."
      }
    end
    agent.state.messages = long_messages

    result = agent.run("Summarize everything")

    expect(result.content).to eq("Compacted response.")
    # After compaction we should have a summary message + preserved + new user + assistant
    summary_msg = result.messages.find { |m| m[:role] == :system && m[:content].to_s.include?("Conversation Summary") }
    expect(summary_msg).not_to be_nil
  end

  # -----------------------------------------------------------------------
  # 9. Applies transform_context before each LLM call
  # -----------------------------------------------------------------------
  it "applies transform_context before each LLM call" do
    transformed = false

    stub_request(:post, gemini_stream_url)
      .to_return(status: 200, body: gemini_text_response("Transformed!"), headers: sse_headers)

    transform = lambda do |state|
      transformed = true
      state.system_prompt = "You are a helpful assistant."
    end

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(
      system_prompt: default_system,
      model: model,
      transform_context: transform
    )
    result = agent.run("Hello")

    expect(transformed).to be true
    expect(result.content).to eq("Transformed!")
    expect(agent.state.system_prompt).to eq("You are a helpful assistant.")
  end

  # -----------------------------------------------------------------------
  # 10. Fires before_tool_call and after_tool_call hooks
  # -----------------------------------------------------------------------
  it "fires before_tool_call and after_tool_call hooks" do
    stub_request(:post, gemini_stream_url)
      .to_return(
        { status: 200, body: gemini_tool_call_response("ping", {}), headers: sse_headers },
        { status: 200, body: gemini_text_response("Pong received."), headers: sse_headers }
      )

    ping_tool = RubyPi::Tool.define(
      name: "ping",
      description: "Ping",
      parameters: RubyPi::Schema.object
    ) { |_args| "pong" }

    registry = RubyPi::Tools::Registry.new
    registry.register(ping_tool)

    hook_log = []
    before = ->(tc) { hook_log << [:before, tc.name] }
    after  = ->(tc, _result) { hook_log << [:after, tc.name] }

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(
      system_prompt: default_system,
      model: model,
      tools: registry,
      before_tool_call: before,
      after_tool_call: after
    )

    agent.run("Ping me")

    expect(hook_log).to eq([[:before, "ping"], [:after, "ping"]])
  end

  # -----------------------------------------------------------------------
  # 11. Falls back to secondary provider on primary failure
  # -----------------------------------------------------------------------
  it "falls back to secondary provider on primary failure" do
    # Primary (Gemini stream) fails with 500.
    stub_request(:post, gemini_stream_url)
      .to_return(status: 500, body: '{"error":"internal"}', headers: json_headers)

    # Fallback (OpenAI) succeeds — also via streaming.
    stub_request(:post, openai_url)
      .to_return(status: 200, body: openai_streaming_response("Fallback answer."), headers: sse_headers)

    primary  = RubyPi::LLM.model(:gemini, "gemini-2.0-flash",
                                  max_retries: 1, retry_base_delay: 0.001, retry_max_delay: 0.001)
    fallback = RubyPi::LLM.model(:openai, "gpt-4o",
                                  max_retries: 1, retry_base_delay: 0.001, retry_max_delay: 0.001)
    provider = RubyPi::LLM::Fallback.new(
      primary: primary,
      fallback: fallback,
      max_retries: 1, retry_base_delay: 0.001, retry_max_delay: 0.001
    )

    agent = RubyPi::Agent.new(system_prompt: default_system, model: provider)
    result = agent.run("Help me")

    expect(result.content).to eq("Fallback answer.")
  end

  # -----------------------------------------------------------------------
  # 12. Surfaces errors via the :error event and Result#error
  # -----------------------------------------------------------------------
  it "surfaces errors via the :error event and Result#error" do
    stub_request(:post, gemini_stream_url)
      .to_return(status: 500, body: '{"error":"boom"}', headers: json_headers)

    errors = []
    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash",
                              max_retries: 1, retry_base_delay: 0.001, retry_max_delay: 0.001)
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model)
    agent.on(:error) { |e| errors << e }

    result = agent.run("Fail please")

    # The agent loop catches StandardError, emits :error, and returns a Result
    # carrying the error rather than re-raising.
    expect(result).not_to be_success
    expect(result.error).to be_a(RubyPi::ApiError)
    expect(errors.length).to be >= 1
    expect(errors.first[:error]).to be_a(RubyPi::ApiError)
    expect(errors.first[:source]).to eq(:agent_loop)
  end

  # -----------------------------------------------------------------------
  # 13. Extension registers and receives events
  # -----------------------------------------------------------------------
  it "registers an extension and receives events" do
    stub_request(:post, gemini_stream_url)
      .to_return(status: 200, body: gemini_text_response("Extended!"), headers: sse_headers)

    received = []
    log_extension_class = Class.new(RubyPi::Extensions::Base)
    log_extension_class.on_event(:turn_start) { |data, _agent| received << [:turn_start, data] }
    log_extension_class.on_event(:agent_end)  { |data, _agent| received << [:agent_end, data] }

    model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    agent = RubyPi::Agent.new(system_prompt: default_system, model: model)
    agent.use(log_extension_class)
    result = agent.run("Hello with extension")

    expect(result.content).to eq("Extended!")
    event_types = received.map(&:first)
    expect(event_types).to include(:turn_start, :agent_end)
  end
end
