# frozen_string_literal: true

# spec/ruby_pi/fixes/review_round4_spec.rb
#
# Tests for the round-4 review fixes:
#   C1 — Faraday transport errors are wrapped into RubyPi::TimeoutError /
#        RubyPi::ApiError and run through the retry loop.
#   C2 — Gemini renders assistant tool_calls as functionCall parts so
#        multi-turn tool use produces a valid request body.
#   C3 — Compaction strips orphan :tool messages from the head of preserved
#        when their matching assistant tool_calls is in droppable.
#   M1 — Tools::Executor captures non-StandardError exceptions raised in a
#        tool block as a failed Result instead of returning a nil success.
#   M2 — Gemini tool_call IDs are unique across turns.
#   m6 — OpenAI rejects malformed JSON in assistant tool_call.arguments
#        with a typed ProviderError before sending the request.

require "spec_helper"

RSpec.describe "Round-4 review fixes" do
  describe "C1: Faraday transport errors wrap to RubyPi typed errors" do
    let(:provider) { RubyPi::LLM::OpenAI.new(model: "gpt-4o", api_key: "test") }
    let(:messages) { [{ role: "user", content: "Hi" }] }

    before do
      RubyPi.configure { |c| c.max_retries = 0; c.retry_base_delay = 0.001 }
    end

    it "raises RubyPi::TimeoutError on Faraday::TimeoutError" do
      # WebMock's #to_timeout raises Faraday::ConnectionFailed via net_http,
      # not Faraday::TimeoutError. Use to_raise to test the real timeout path.
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_raise(Faraday::TimeoutError.new("read timeout"))

      expect {
        provider.complete(messages: messages, stream: false)
      }.to raise_error(RubyPi::TimeoutError, /openai request timed out/)
    end

    it "raises RubyPi::ApiError on Faraday::ConnectionFailed" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_raise(Faraday::ConnectionFailed.new("connection refused"))

      expect {
        provider.complete(messages: messages, stream: false)
      }.to raise_error(RubyPi::ApiError, /openai transport error/)
    end

    it "retries on RubyPi::TimeoutError and eventually succeeds" do
      RubyPi.configure { |c| c.max_retries = 2; c.retry_base_delay = 0.001 }
      retry_provider = RubyPi::LLM::OpenAI.new(model: "gpt-4o", api_key: "test")

      success_body = JSON.generate({
        choices: [{ message: { role: "assistant", content: "ok" }, finish_reason: "stop" }],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
      })

      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_raise(Faraday::TimeoutError.new("read timeout")).then
        .to_return(status: 200, body: success_body, headers: { "Content-Type" => "application/json" })

      response = retry_provider.complete(messages: messages, stream: false)
      expect(response.content).to eq("ok")
    end
  end

  describe "C2: Gemini renders assistant tool_calls as functionCall parts" do
    let(:provider) { RubyPi::LLM::Gemini.new(model: "gemini-2.0-flash", api_key: "test") }

    before do
      stub_request(:post, %r{streamGenerateContent})
        .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: "")
      stub_request(:post, %r{:generateContent})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({
            candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }]
          })
        )
    end

    it "emits functionCall part(s) on a model turn that carried tool_calls" do
      messages = [
        { role: :user, content: "weather in NYC?" },
        {
          role: :assistant,
          content: nil,
          tool_calls: [
            { id: "gemini_abc", name: "get_weather", arguments: { city: "NYC" } }
          ]
        },
        { role: :tool, content: '{"temp":72}', tool_call_id: "gemini_abc", name: "get_weather" },
        { role: :user, content: "thanks" }
      ]

      provider.complete(messages: messages, stream: false)

      expect(WebMock).to have_requested(:post, %r{:generateContent}).with { |req|
        body = JSON.parse(req.body)
        model_turn = body["contents"].find { |c| c["role"] == "model" }
        fc = model_turn["parts"].find { |p| p.key?("functionCall") }
        fc &&
          fc["functionCall"]["name"] == "get_weather" &&
          fc["functionCall"]["args"] == { "city" => "NYC" }
      }
    end

    it "does not include an empty text part when the assistant turn is tool-only" do
      messages = [
        { role: :user, content: "hi" },
        {
          role: :assistant,
          content: nil,
          tool_calls: [{ id: "x", name: "f", arguments: {} }]
        },
        { role: :tool, content: "1", tool_call_id: "x", name: "f" }
      ]

      provider.complete(messages: messages, stream: false)

      expect(WebMock).to have_requested(:post, %r{:generateContent}).with { |req|
        body = JSON.parse(req.body)
        model_turn = body["contents"].find { |c| c["role"] == "model" }
        # Only a functionCall part — no { text: "..." } part with content.
        text_parts = model_turn["parts"].select { |p| p.key?("text") && !p["text"].to_s.empty? }
        text_parts.empty?
      }
    end
  end

  describe "C3: Compaction strips orphan :tool messages from preserved" do
    let(:summary_model) do
      instance_double(
        RubyPi::LLM::Gemini,
        complete: RubyPi::LLM::Response.new(content: "summary", tool_calls: [], usage: {}, finish_reason: "stop")
      )
    end

    it "moves an orphan :tool at the head of preserved into droppable" do
      compaction = RubyPi::Context::Compaction.new(
        max_tokens: 50, summary_model: summary_model, preserve_last_n: 2
      )

      long = "x" * 400
      msgs = [
        { role: :user, content: long },
        { role: :assistant, content: long, tool_calls: [{ id: "t1", name: "x", arguments: {} }] },
        { role: :tool, content: "result", tool_call_id: "t1", name: "x" }, # would be preserved[0]
        { role: :assistant, content: "ack" }                               # preserved[1]
      ]

      result = compaction.compact(msgs, "system")
      expect(result.none? { |m| m[:role] == :tool }).to be(true)
    end
  end

  describe "M1: Executor captures Exception (not just StandardError)" do
    let(:registry) { RubyPi::Tools::Registry.new }

    it "captures a non-StandardError raise as a failed Result" do
      tool = RubyPi::Tool.define(name: "boom", description: "raises") do |_args|
        raise SignalException.new("INT")
      end
      registry.register(tool)

      executor = RubyPi::Tools::Executor.new(registry, mode: :sequential, timeout: 5)
      results = executor.execute([{ name: "boom", arguments: {} }])

      expect(results.first.success?).to be(false)
      expect(results.first.error).to include("SignalException")
    end
  end

  describe "M2: Gemini tool call IDs are unique across responses" do
    let(:provider) { RubyPi::LLM::Gemini.new(model: "gemini-2.0-flash", api_key: "test") }

    it "generates distinct IDs for sequential responses with one tool call each" do
      body = JSON.generate({
        candidates: [{
          content: { parts: [{ functionCall: { name: "f", args: {} } }] },
          finishReason: "STOP"
        }]
      })
      stub_request(:post, %r{:generateContent}).to_return(
        status: 200, body: body, headers: { "Content-Type" => "application/json" }
      )

      r1 = provider.complete(messages: [{ role: :user, content: "a" }], stream: false)
      r2 = provider.complete(messages: [{ role: :user, content: "b" }], stream: false)

      id1 = r1.tool_calls.first.id
      id2 = r2.tool_calls.first.id

      expect(id1).to start_with("gemini_")
      expect(id2).to start_with("gemini_")
      expect(id1).not_to eq(id2)
    end
  end

  describe "m6: OpenAI rejects malformed assistant tool_call.arguments JSON" do
    let(:provider) { RubyPi::LLM::OpenAI.new(model: "gpt-4o", api_key: "test") }

    it "raises RubyPi::ProviderError before sending the request" do
      messages = [
        { role: :user, content: "hi" },
        {
          role: :assistant,
          content: nil,
          tool_calls: [{ id: "tc1", name: "f", arguments: "{this is not json" }]
        }
      ]

      expect {
        provider.complete(messages: messages, stream: false)
      }.to raise_error(RubyPi::ProviderError, /Invalid JSON in assistant tool_call/)
    end

    it "passes through a valid JSON string verbatim" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          choices: [{ message: { role: "assistant", content: "ok" }, finish_reason: "stop" }]
        })
      )

      messages = [
        { role: :user, content: "hi" },
        {
          role: :assistant,
          content: nil,
          tool_calls: [{ id: "tc1", name: "f", arguments: '{"x":1}' }]
        },
        { role: :tool, content: "1", tool_call_id: "tc1", name: "f" }
      ]

      provider.complete(messages: messages, stream: false)

      expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").with { |req|
        body = JSON.parse(req.body)
        asst = body["messages"].find { |m| m["role"] == "assistant" }
        asst["tool_calls"].first["function"]["arguments"] == '{"x":1}'
      }
    end
  end
end
