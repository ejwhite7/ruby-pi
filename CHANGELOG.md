# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
