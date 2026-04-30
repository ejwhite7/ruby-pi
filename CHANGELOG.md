# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.5] - 2026-04-30

### Fixed (adversarial review round 3)

- **Streaming error body recovery — Gemini and OpenAI**: The 0.1.4 fix accumulated `error_body` in the `on_data` callback for all three providers but only Anthropic actually passed it to `handle_error_response`. Gemini (`gemini.rb`) and OpenAI (`openai.rb`) now also pass `override_body: error_body` so `ApiError#response_body` carries the real server error message on streaming HTTP failures, matching Anthropic's behavior
- **Compaction consecutive same-role messages**: The 0.1.4 fix changed the summary role from `:user` to `:assistant` to avoid consecutive user messages, but produced consecutive assistants when the first preserved message was already `:assistant`. The summary role is now chosen based on the first preserved message's role: `:user` when the next message is `:assistant`, `:assistant` otherwise. New compaction spec exercises both orderings
- **`:fallback_start` not surfaced to agent users**: `RubyPi::LLM::Fallback` emits a `:fallback_start` `StreamEvent` when the primary fails mid-stream, but the agent loop's stream block only handled `:text_delta` and `:tool_call_delta`, dropping the signal. The loop now translates `:fallback_start` into a new agent-level `:provider_fallback` event, and clears the streamed-content accumulator so the recorded response reflects only the fallback's output. Subscribers register with `agent.on(:provider_fallback) { |e| ... }`
- **`StreamEvent#fallback_start?` predicate**: Added to match `text_delta?`, `tool_call_delta?`, and `done?` so consumers can branch on it without comparing `event.type` directly
- **Tool result JSON serialization crash**: `Loop#act` called `JSON.generate(result.value)` unconditionally; tools returning Time, Date, or other non-JSON-serializable objects raised `JSON::GeneratorError` and aborted the agent run. The serialization is now wrapped in a rescue that falls back to `result.value.to_s`
- **`tool_calls_made` argument shape inconsistency**: The arguments recorded in `Result#tool_calls_made` were the raw string-keyed `JSON.parse` output, while the tool block itself received the symbol-keyed copy `Tools::Executor` produces. Both now use the symbolized form, and `Tools::Executor.deep_symbolize_keys` is exposed as a public class method so the loop can apply the same transformation up front
- **`Agent::Core` `config:` kwarg honesty**: The 0.1.4 changelog claimed the kwarg "flows through to provider construction." It does not — the model is constructed before the agent. The kwarg is informational only; users who want per-agent provider config must pass `config:` to the model factory: `RubyPi::LLM.model(:openai, "gpt-4o", config: cfg)`. The Agent::Core docstring and CHANGELOG now reflect this
- **CHANGELOG references to nonexistent `BufferedStreamProxy`**: The 0.1.4 entry referenced a `BufferedStreamProxy` class that does not exist in the codebase; the buffering logic was inline in `Fallback`. Removed those references
- **CLAUDE.md provider/extension guides**: "Adding a New LLM Provider" still referenced the deleted `parse_sse_events` helper; updated to describe the `on_data` streaming pattern. The `:agent_end` extension example used `event[:iterations]` (no such key) — replaced with `event[:result].turns`. Added `:tool_call_delta` and `:provider_fallback` to the available events list
- **README streaming docs**: Documented the `:fallback_start` stream event and the agent-level `:provider_fallback` event with payload schema

## [0.1.4] - 2026-04-30

### Fixed (adversarial review round 2)

- **Anthropic ProviderError string interpolation**: Removed backslash-escaping on `#{}` interpolation in the ProviderError message for malformed tool call JSON, so actual tool name and parser error appear instead of literal `\#{...}` text
- **Thread-unsafe streaming instance variables**: Replaced `@_stream_*` instance variables in Anthropic provider with method-local variables via a `process_anthropic_stream_event` helper that returns updated state as a hash, making streaming safe for concurrent requests
- **Streaming error body recovery (Anthropic)**: Anthropic's streaming path now detects HTTP error status in the `on_data` callback, accumulates the error response body separately, and passes it to `handle_error_response` via the new `override_body:` kwarg so `ApiError#response_body` carries the server's error message even though `on_data` consumed the response. (Note: 0.1.5 extends this to Gemini and OpenAI, which were missed in 0.1.4)
- **Compaction `:system` poisoning**: Changed compaction summary role from `:system` to a non-system role to prevent overwriting the real system prompt on Anthropic. (Note: 0.1.5 refines the role choice to also avoid consecutive same-role messages)
- **OpenAI missing tool_call_id**: OpenAI provider now raises `RubyPi::ProviderError` on nil/blank `tool_call_id` in tool result messages and assistant tool calls (same fail-fast pattern as Anthropic), instead of silently sending `"unknown"`
- **Gemini streaming finish_reason**: Streaming responses now parse the actual `finishReason` from the Gemini candidate object instead of hardcoding `"stop"`
- **README incorrect event keys**: Fixed `e[:iteration]` to `e[:turn]` and `event[:iterations]` to `event[:result].turns` throughout README examples
- **Dead `parse_sse_events` method**: Removed unused `parse_sse_events` from `BaseProvider` (all providers now use real incremental streaming via `on_data`)
- **`faraday-net_http` version cap**: Removed arbitrary `< 3.4` upper bound from both Gemfile and gemspec
- **`Fallback` no longer buffers happy-path streams**: `Fallback#perform_complete_with_streaming_fallback` previously buffered all primary events and flushed them after completion, destroying the streaming UX even when nothing went wrong. Events now flow through to the consumer in real time. On primary failure, a `:fallback_start` `StreamEvent` is emitted before the fallback streams, signaling consumers to clear partial output

#### Previously Addressed (adversarial review round 1, 35 items)

- API key exposure in Gemini URL query strings (moved to header)
- Provider `format_tool` accepting `Definition` objects
- Retry-after header parsing for `RateLimitError`
- Max iterations boundary condition (off-by-one)
- Token usage accumulation across turns
- Agent result `success?` semantics for max-iteration stops
- Context compaction system prompt poisoning
- `nil` tool guard in executor
- Tool call ID validation (Anthropic fail-fast)
- Streaming event types (`:text_delta` for text, `:tool_call_delta` for tools)
- Concurrent tool execution thread safety
- `before_tool_call` / `after_tool_call` lifecycle hooks
- `transform_context` pipeline support
- Extension base class DSL (`on_event`, `before_tool`, `after_tool`)
- `Agent::Core#config:` kwarg accepted (informational only — pass `config:` to the model factory to actually override provider config)
- Typed error hierarchy with `response_body` on `ApiError`
- `ostruct` runtime dependency declaration
- Comprehensive test coverage (440+ examples)

## [0.1.3] - 2026-04-29

### Added

- `RubyPi::Agent::Core#initialize` now accepts a `messages:` keyword argument so callers can seed the agent with prior conversation history when starting a run

## [0.1.2] - 2026-04-29

### Fixed

- Anthropic provider: tool result messages (`role: "tool"`) are now converted to `role: "user"` with `tool_result` content blocks containing the matching `tool_use_id`, and consecutive tool results from the same turn are grouped into a single user message as the Messages API requires
- Anthropic provider: assistant messages with `tool_calls` are now preserved as `tool_use` content blocks (`{type: "tool_use", id:, name:, input:}`) instead of being silently discarded, so the API can match them to subsequent tool results
- Anthropic and OpenAI providers: structured `content` (Arrays/Hashes, e.g. multimodal vision payloads) is preserved as-is instead of being collapsed by `to_s`
- OpenAI provider: tool messages now include `tool_call_id` and assistant `tool_calls` are emitted in the full OpenAI function-call structure for proper result matching

### Added

- Comprehensive unit tests for `build_request_body` in both Anthropic and OpenAI providers covering full agent-loop conversations, consecutive tool result grouping, structured content preservation, and string- vs symbol-keyed message edge cases

## [0.1.1] - 2026-04-28

### Changed

- Rewrote gem `summary` and `description` for RubyGems search discoverability around terms like "AI agent harness", "LLM agent", "tool calling", and the supported providers
- Declared `rubygems_mfa_required` in gemspec metadata

### Fixed

- Provider `format_tool` methods now accept `RubyPi::Tools::Definition` objects (not just hashes), unblocking the agent loop for any tool-using flow
- `ostruct` declared as a runtime dependency so the gem loads on Ruby 4.x where it is no longer a default gem
- Integration spec rewritten against the current `Agent` API; full suite green (309 examples)

## [0.1.0] - 2026-04-28

### Added

- `RubyPi::LLM` with Gemini, Anthropic, and OpenAI providers
- Unified `Response`, `ToolCall`, and `StreamEvent` value objects
- `BaseProvider` with automatic retry and exponential backoff with jitter
- Streaming support via Faraday SSE parsing for all providers
- `RubyPi::LLM::Fallback` for automatic provider failover
- `RubyPi::LLM::Model` descriptor for deferred provider construction
- `RubyPi::Tools::Definition` with `RubyPi::Tool.define` convenience API
- `RubyPi::Schema` DSL for building JSON Schema parameter definitions
- `RubyPi::Tools::Registry` -- thread-safe tool store with category filtering and subset extraction
- `RubyPi::Tools::Executor` -- parallel and sequential tool dispatch with per-tool timeouts
- `RubyPi::Tools::Result` -- execution outcome with value/error and timing
- `RubyPi::Agent` with think-act-observe loop
- Event system (`text_delta`, `tool_execution_start`, `tool_execution_end`, `turn_start`, `turn_end`, `before_tool_call`, `after_tool_call`, `agent_end`, `error`)
- `RubyPi::Context::Compaction` for long-context management
- `RubyPi::Context::Transform` helpers for message list preprocessing
- `RubyPi::Extensions::Base` hook DSL for cross-cutting agent behavior
- `RubyPi::Configuration` with API keys, retry settings, timeouts, and default models
- Typed error hierarchy (`ApiError`, `AuthenticationError`, `RateLimitError`, `TimeoutError`, `ProviderError`)
- Full RSpec test suite with WebMock (unit + integration)
- GitHub Actions CI for Ruby 3.2 and 3.3
