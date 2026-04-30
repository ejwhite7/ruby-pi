# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_12_15_22_json_parsing_spec.rb
#
# Tests for Issues #12, #15, #22:
# - #12: JSON.parse("") crashes in OpenAI and Anthropic
# - #15: ToolCall#parse_arguments crashes on non-string non-hash inputs
# - #22: Anthropic streaming JSON.parse unguarded

require "spec_helper"

RSpec.describe "Issues #12, #15, #22: JSON parsing guards" do
  # Issue #12: OpenAI parse_response with empty-string arguments
  describe "Issue #12: OpenAI empty-string arguments" do
    let(:provider) { RubyPi::LLM::OpenAI.new(model: "gpt-4o", api_key: "test-key") }
    let(:api_url) { "https://api.openai.com/v1/chat/completions" }

    it "handles empty-string arguments without crashing" do
      stub_request(:post, api_url).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          choices: [{
            message: {
              role: "assistant",
              content: nil,
              tool_calls: [{
                id: "call_1",
                type: "function",
                function: { name: "my_tool", arguments: "" }
              }]
            },
            finish_reason: "tool_calls"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        })
      )

      response = provider.complete(messages: [{ role: "user", content: "test" }])
      expect(response.tool_calls.size).to eq(1)
      expect(response.tool_calls.first.arguments).to eq({})
    end

    it "handles nil arguments without crashing" do
      stub_request(:post, api_url).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          choices: [{
            message: {
              role: "assistant",
              content: nil,
              tool_calls: [{
                id: "call_1",
                type: "function",
                function: { name: "my_tool", arguments: nil }
              }]
            },
            finish_reason: "tool_calls"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        })
      )

      response = provider.complete(messages: [{ role: "user", content: "test" }])
      expect(response.tool_calls.first.arguments).to eq({})
    end

    it "handles whitespace-only arguments without crashing" do
      stub_request(:post, api_url).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          choices: [{
            message: {
              role: "assistant",
              content: nil,
              tool_calls: [{
                id: "call_1",
                type: "function",
                function: { name: "my_tool", arguments: "   " }
              }]
            },
            finish_reason: "tool_calls"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        })
      )

      response = provider.complete(messages: [{ role: "user", content: "test" }])
      expect(response.tool_calls.first.arguments).to eq({})
    end

    it "raises ProviderError for invalid JSON arguments" do
      stub_request(:post, api_url).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          choices: [{
            message: {
              role: "assistant",
              content: nil,
              tool_calls: [{
                id: "call_1",
                type: "function",
                function: { name: "my_tool", arguments: "{invalid json" }
              }]
            },
            finish_reason: "tool_calls"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        })
      )

      expect {
        provider.complete(messages: [{ role: "user", content: "test" }])
      }.to raise_error(RubyPi::ProviderError, /Failed to parse tool call arguments/)
    end
  end

  # Issue #15: ToolCall#parse_arguments with non-string inputs
  describe "Issue #15: ToolCall with non-string, non-hash arguments" do
    it "handles Integer arguments without NoMethodError" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: 42)
      expect(tc.arguments).to be_a(Hash)
      expect(tc.arguments["_raw"]).to eq("42")
    end

    it "handles Float arguments" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: 3.14)
      expect(tc.arguments).to be_a(Hash)
    end

    it "handles nil arguments" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: nil)
      expect(tc.arguments).to eq({})
    end

    it "handles empty-string arguments" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: "")
      expect(tc.arguments).to eq({})
    end

    it "handles whitespace-only string arguments" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: "  \n ")
      expect(tc.arguments).to eq({})
    end

    it "handles Array arguments" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: [1, 2, 3])
      expect(tc.arguments).to be_a(Hash)
    end

    it "handles boolean arguments" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: true)
      expect(tc.arguments).to be_a(Hash)
    end

    it "still parses valid JSON string arguments correctly" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: '{"key": "value"}')
      expect(tc.arguments).to eq({ "key" => "value" })
    end

    it "handles Hash arguments unchanged" do
      tc = RubyPi::LLM::ToolCall.new(id: "1", name: "test", arguments: { key: "value" })
      expect(tc.arguments).to eq({ key: "value" })
    end
  end

  # Issue #22: Anthropic streaming JSON.parse unguarded
  describe "Issue #22: Anthropic streaming truncated JSON" do
    let(:provider) { RubyPi::LLM::Anthropic.new(model: "claude-sonnet-4-20250514", api_key: "test-key") }
    let(:api_url) { "https://api.anthropic.com/v1/messages" }

    it "raises ProviderError on truncated tool call JSON" do
      # Simulate a streaming response where the tool call JSON is truncated
      sse_body = [
        'data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}',
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_1","name":"my_tool"}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"key\":"}}',
        # Stream truncated here — missing the closing brace
        'data: {"type":"content_block_stop","index":0}',
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}'
      ].join("\n")

      stub_request(:post, api_url).to_return(
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: sse_body
      )

      expect {
        provider.complete(
          messages: [{ role: "user", content: "test" }],
          tools: [{ name: "my_tool", description: "test tool" }],
          stream: true
        ) { |_| }
      }.to raise_error(RubyPi::ProviderError, /Failed to parse streaming tool call arguments/)
    end

    it "handles empty tool call JSON gracefully" do
      sse_body = [
        'data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}',
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_1","name":"my_tool"}}',
        # No input_json_delta events — empty arguments
        'data: {"type":"content_block_stop","index":0}',
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}'
      ].join("\n")

      stub_request(:post, api_url).to_return(
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: sse_body
      )

      events = []
      response = provider.complete(
        messages: [{ role: "user", content: "test" }],
        tools: [{ name: "my_tool", description: "test tool" }],
        stream: true
      ) { |e| events << e }

      expect(response.tool_calls.size).to eq(1)
      expect(response.tool_calls.first.arguments).to eq({})
    end
  end
end
