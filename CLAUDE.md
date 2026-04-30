# CLAUDE.md -- ruby-pi Development Guide

This file contains essential context for developers (and AI agents) working on the `ruby-pi` gem. Read this before making changes.

---

## What This Is

RubyPi is a minimal, composable Ruby gem for building LLM-powered agents. It provides:

- A unified interface across Gemini, Anthropic, and OpenAI
- A tool definition DSL with JSON Schema parameter validation
- A think-act-observe agent loop with streaming and events
- Context management (compaction and transforms)
- An extension hook system for cross-cutting concerns

The design philosophy is **anti-framework**: small modules, no global state beyond configuration, explicit over magical.

---

## Architecture

```
RubyPi.configure          Global config (API keys, retries, timeouts)
       |
RubyPi::LLM              Provider abstraction layer
  |-- BaseProvider        Abstract base with retry logic
  |-- Gemini              Google Gemini REST API
  |-- Anthropic           Anthropic Messages API
  |-- OpenAI              OpenAI Chat Completions API
  |-- Fallback            Primary/fallback provider chain
  |-- Response            Normalized completion result
  |-- ToolCall            Structured tool invocation
  +-- StreamEvent         Streaming event (:text_delta, :tool_call_delta, :done)

RubyPi::Tools             Tool definition and execution
  |-- Definition          Name, description, parameters, callable block
  |-- Schema              JSON Schema DSL builder
  |-- Registry            Thread-safe tool store
  |-- Executor            Parallel/sequential tool dispatch
  +-- Result              Execution outcome (value or error + timing)

RubyPi::Agent             Think-act-observe loop
  +-- Result              Agent run outcome (output, messages, iterations)

RubyPi::Context           Conversation context management
  |-- Compaction          Truncate/summarize to fit token limits
  +-- Transform           Arbitrary message list transformations

RubyPi::Extensions        Hook system for agent events
  +-- Base                DSL for subscribing to lifecycle events
```

---

## Module Map (with file paths)

```
lib/
  ruby_pi.rb                          # Entry point, requires everything, LLM.model factory
  ruby_pi/
    version.rb                        # RubyPi::VERSION = "0.1.0"
    configuration.rb                  # RubyPi::Configuration (API keys, retries, defaults)
    errors.rb                         # Error hierarchy (ApiError, AuthenticationError, etc.)
    llm/
      base_provider.rb                # Abstract base: retry, backoff, SSE parsing, Faraday
      gemini.rb                       # Google Gemini provider
      anthropic.rb                    # Anthropic Claude provider
      openai.rb                       # OpenAI provider
      fallback.rb                     # Fallback wrapper (primary + backup)
      model.rb                        # Model descriptor (provider + name)
      response.rb                     # Normalized Response object
      tool_call.rb                    # ToolCall value object
      stream_event.rb                 # StreamEvent value object
    tools/
      definition.rb                   # Tool Definition + RubyPi::Tool.define
      schema.rb                       # RubyPi::Schema DSL
      registry.rb                     # Thread-safe Registry
      executor.rb                     # Parallel/sequential Executor
      result.rb                       # Execution Result
    agent/
      agent.rb                        # RubyPi::Agent (think-act-observe loop)
      result.rb                       # Agent::Result (output, messages, iterations)
    context/
      compaction.rb                   # Context::Compaction
      transform.rb                    # Context::Transform
    extensions/
      base.rb                         # Extensions::Base (on_event DSL)

spec/
  spec_helper.rb                      # RSpec + WebMock setup
  ruby_pi/
    llm/                              # Unit tests for each LLM provider
    tools/                            # Unit tests for tools, registry, executor
  integration/
    agent_integration_spec.rb         # End-to-end agent loop tests
```

---

## Design Principles

1. **No global mutable state** beyond `RubyPi.configuration`. Everything else is instance-scoped.
2. **Explicit dependencies.** Agent receives model, tools, extensions as constructor args -- no service locator.
3. **Provider-agnostic responses.** `Response`, `ToolCall`, and `StreamEvent` are the same regardless of which LLM you use.
4. **Composable, not coupled.** You can use `RubyPi::LLM` without `Agent`, or `Tools` without `LLM`.
5. **Errors are typed.** The error hierarchy (`ApiError`, `RateLimitError`, `AuthenticationError`, `TimeoutError`) lets callers rescue precisely.
6. **Thread safety.** Registry uses a Mutex; Executor uses `concurrent-ruby` futures.
7. **Test-friendly.** All HTTP goes through Faraday, which WebMock intercepts cleanly.

---

## Development Commands

```bash
# Install dependencies
bundle install

# Run the full test suite
bundle exec rspec

# Run tests with documentation format
bundle exec rspec --format documentation

# Run only integration tests
bundle exec rspec spec/integration/

# Run a specific test file
bundle exec rspec spec/ruby_pi/llm/gemini_spec.rb

# Run tests matching a pattern
bundle exec rspec -e "streaming"

# Lint (if rubocop is added)
bundle exec rubocop
```

---

## Adding a New LLM Provider

1. Create `lib/ruby_pi/llm/my_provider.rb`
2. Subclass `RubyPi::LLM::BaseProvider`
3. Implement three methods:
   - `model_name` -- returns the model string
   - `provider_name` -- returns a Symbol (e.g., `:my_provider`)
   - `perform_complete(messages:, tools:, stream:, &block)` -- makes the HTTP call and returns a `Response`
4. Use `build_connection(base_url:, headers:)` for Faraday setup
5. Use `handle_error_response(response)` to raise typed errors
6. Use `parse_sse_events(body) { |data| ... }` for streaming
7. Add the provider to the `case` statement in `RubyPi::LLM.model` (in `lib/ruby_pi.rb`)
8. Add `require_relative` for the new file in `lib/ruby_pi.rb`
9. Write specs in `spec/ruby_pi/llm/my_provider_spec.rb` following the existing pattern
10. Add a config attribute (e.g., `my_provider_api_key`) to `Configuration` if needed

---

## Adding a New Context Transform

`RubyPi::Context::Transform` is a module with factory methods, not a class. Use the built-in
transforms or write a custom lambda:

```ruby
# Using built-in transforms:
transform = RubyPi::Context::Transform.compose(
  RubyPi::Context::Transform.inject_datetime,
  RubyPi::Context::Transform.inject_user_preferences { |state| state.user_data[:prefs] }
)

# Or a custom lambda (receives Agent::State, mutates in place):
transform = ->(state) { state.system_prompt += "\nExtra context." }
```

Pass it to `Agent.new(transform_context: transform)`.

The callable receives the `Agent::State` object and can mutate it (typically appending to `system_prompt`).

---

## Adding a New Extension

1. Subclass `RubyPi::Extensions::Base`
2. Use `on_event :event_name do |event| ... end` to subscribe to events
3. Available events: `:turn_start`, `:turn_end`, `:text_delta`, `:tool_execution_start`, `:tool_execution_end`, `:agent_end`, `:error`, `:compaction`
   Note: `:before_tool_call` and `:after_tool_call` are constructor hooks (Procs on Agent::Core), not subscribable events.
4. Register the extension: `agent.use(MyExtension)` (pass the CLASS, not an instance)

```ruby
class MyExtension < RubyPi::Extensions::Base
  on_event :agent_end do |event|
    puts "Agent finished after #{event[:iterations]} iterations"
  end
end
```

---

## Test Strategy

- **Unit tests** (`spec/ruby_pi/`): One spec file per source file. Mock HTTP responses with WebMock. Test each class in isolation.
- **Integration tests** (`spec/integration/`): End-to-end agent loop tests. Stub all HTTP but let the real code path execute through Agent -> LLM -> Tools -> Context.
- **No live API calls.** `WebMock.disable_net_connect!` is set globally in `spec_helper.rb`.
- **Fast retries in tests.** `retry_base_delay` is set to `0.01` and `retry_max_delay` to `0.05` in the before-each block.
- **CI matrix.** GitHub Actions runs against Ruby 3.2, 3.3, and 3.4.

---

## Version & Release Process

1. Update `lib/ruby_pi/version.rb` with the new version number
2. Update `CHANGELOG.md` with the new version's changes
3. Commit: `git commit -am "Release vX.Y.Z"`
4. Tag: `git tag vX.Y.Z`
5. Push: `git push origin main --tags`
6. Build and publish: `gem build ruby_pi.gemspec && gem push ruby_pi-X.Y.Z.gem`

We follow [Semantic Versioning](https://semver.org/):
- **PATCH** (0.1.x): Bug fixes, documentation updates
- **MINOR** (0.x.0): New features, new providers, new extensions (backward compatible)
- **MAJOR** (x.0.0): Breaking API changes
