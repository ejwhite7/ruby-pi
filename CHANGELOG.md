# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
