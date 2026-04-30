# RubyPi

[![Gem Version](https://badge.fury.io/rb/ruby-pi.svg)](https://rubygems.org/gems/ruby-pi)
[![CI](https://github.com/ejwhite7/ruby-pi/actions/workflows/ci.yml/badge.svg)](https://github.com/ejwhite7/ruby-pi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%203.2-red.svg)](https://www.ruby-lang.org)

**A minimal, composable toolkit for building LLM-powered agents in Ruby.**

RubyPi is an anti-framework. Instead of imposing a sprawling abstraction layer, it gives you small, focused modules you can compose however you like: swap providers, define tools, run agent loops, manage context -- all without buying into a monolithic architecture. Every piece works on its own, and they snap together when you need them to.

---

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
  - [RubyPi::LLM](#rubypillm)
  - [RubyPi::Tools](#rubypitools)
  - [RubyPi::Agent](#rubypiagent)
  - [RubyPi::Context](#rubypicontext)
  - [RubyPi::Extensions](#rubypiextensions)
- [Configuration](#configuration)
- [Contributing](#contributing)
- [License](#license)

---

## Installation

Add to your Gemfile:

```ruby
gem "ruby-pi"
```

Then run:

```bash
bundle install
```

Or install directly:

```bash
gem install ruby-pi
```

---

## Quick Start

```ruby
require "ruby_pi"

# 1. Configure
RubyPi.configure do |c|
  c.gemini_api_key = ENV["GEMINI_API_KEY"]
end

# 2. Define a tool
weather = RubyPi::Tool.define(
  name: :get_weather,
  description: "Get the current weather for a city",
  parameters: RubyPi::Schema.object(
    city: RubyPi::Schema.string("City name", required: true)
  )
) { |args| { temp: 72, condition: "sunny", city: args["city"] } }

# 3. Build a registry and an agent
registry = RubyPi::Tools::Registry.new
registry.register(weather)

model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
agent = RubyPi::Agent.new(
  system_prompt: "You are a helpful weather assistant.",
  model: model,
  tools: registry
)

# 4. Subscribe to events
agent.on(:text_delta) { |e| print e[:content] }
agent.on(:tool_execution_end) { |e| puts "\n[Tool] #{e[:tool_name]} => #{e[:result].value}" }

# 5. Run
result = agent.run("What's the weather in San Francisco?")
puts "\nDone: #{result.content}"
```

---

## API Reference

### RubyPi::LLM

The LLM module provides a provider-agnostic interface for text generation, streaming, and tool calling across Gemini, Anthropic, and OpenAI.

#### Model Factory

```ruby
# Build a provider instance
model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
model = RubyPi::LLM.model(:anthropic, "claude-sonnet-4-20250514")
model = RubyPi::LLM.model(:openai, "gpt-4o")
```

#### Completions

```ruby
response = model.complete(
  messages: [{ role: "user", content: "Hello!" }],
  tools: [],       # optional tool definitions
  stream: false    # set true for streaming
)

response.content       # => "Hi there!"
response.tool_calls    # => [] or [ToolCall, ...]
response.tool_calls?   # => false
response.usage         # => { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 }
response.finish_reason # => "stop"
```

#### Streaming

```ruby
model.complete(messages: messages, stream: true) do |event|
  case event.type
  when :text_delta
    print event.data           # incremental text chunk
  when :tool_call_delta
    handle_fragment(event.data) # partial tool call JSON
  when :fallback_start
    # Only emitted by RubyPi::LLM::Fallback when the primary provider
    # fails mid-stream. Discard any partial output rendered from the
    # primary; the fallback provider is about to stream its full reply.
    # Payload: { failed_provider:, error:, fallback_provider: }
    clear_partial_output
  when :done
    puts "\nStream finished"
  end
end
```

When using `RubyPi::Agent`, the loop translates a `:fallback_start` stream
event into an agent-level `:provider_fallback` event you can subscribe to
with `agent.on(:provider_fallback) { |e| ... }`. The agent also discards
any partial text it accumulated from the failed primary so the recorded
response reflects only the fallback's output.

#### Response & ToolCall

| Class | Attributes |
|---|---|
| `RubyPi::LLM::Response` | `content`, `tool_calls`, `usage`, `finish_reason`, `tool_calls?` |
| `RubyPi::LLM::ToolCall` | `id`, `name`, `arguments` |
| `RubyPi::LLM::StreamEvent` | `type`, `data`, `text_delta?`, `tool_call_delta?`, `done?` |

#### Fallback

Automatically fail over to a backup provider when the primary is unavailable:

```ruby
primary  = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
backup   = RubyPi::LLM.model(:openai, "gpt-4o")
provider = RubyPi::LLM::Fallback.new(primary: primary, fallback: backup)

# Uses Gemini; if it 500s or times out, retries with OpenAI
response = provider.complete(messages: messages)
```

Authentication errors (401/403) are **not** retried with the fallback -- they indicate a configuration problem, not a transient failure.

---

### RubyPi::Tools

A lightweight DSL for defining tools (functions) that LLMs can call, plus a registry and executor for dispatching them.

> **`RubyPi::Tool` vs `RubyPi::Tools`:** `RubyPi::Tool.define(...)` is the convenience API
> for creating tool definitions with a clean syntax. `RubyPi::Tools` is the internal namespace
> containing the supporting classes (`Definition`, `Registry`, `Executor`, `Result`, `Schema`).
> Use `RubyPi::Tool.define` in application code; reference `RubyPi::Tools::*` when you need
> direct access to the underlying components.

#### Defining Tools

```ruby
tool = RubyPi::Tool.define(
  name: :create_post,
  description: "Create a social media post",
  category: :content,
  parameters: RubyPi::Schema.object(
    content: RubyPi::Schema.string("Post body", required: true),
    tags: RubyPi::Schema.array(
      description: "Tags",
      items: RubyPi::Schema.string("A tag")
    )
  )
) do |args|
  { post_id: SecureRandom.uuid, status: "published" }
end
```

#### Schema DSL

Build JSON Schema hashes with a fluent Ruby API:

```ruby
RubyPi::Schema.string("A label", required: true, enum: ["a", "b"])
RubyPi::Schema.integer("Count", minimum: 0, maximum: 100)
RubyPi::Schema.number("Price", minimum: 0.0)
RubyPi::Schema.boolean("Active")
RubyPi::Schema.array(description: "Items", items: RubyPi::Schema.string)
RubyPi::Schema.object(name: RubyPi::Schema.string("Name", required: true))
```

#### Registry

```ruby
registry = RubyPi::Tools::Registry.new
registry.register(tool)

registry.find(:create_post)          # => Definition or nil
registry.registered?(:create_post)   # => true
registry.names                       # => [:create_post]
registry.size                        # => 1
registry.by_category(:content)       # => [Definition, ...]
registry.subset([:create_post])      # => new Registry with just that tool
registry.all                         # => [Definition, ...]
```

#### Executor

Run tool calls in parallel or sequentially with automatic error handling and timeouts:

```ruby
executor = RubyPi::Tools::Executor.new(registry, mode: :parallel, timeout: 30)

results = executor.execute([
  { name: "create_post", arguments: { content: "Hello" } },
  { name: "get_analytics", arguments: { period: "7d" } }
])

results.each do |r|
  if r.success?
    puts "#{r.name}: #{r.value}"
  else
    puts "#{r.name} failed: #{r.error} (#{r.duration_ms}ms)"
  end
end
```

| `Result` attribute | Description |
|---|---|
| `name` | Tool name |
| `success?` | Whether the call succeeded |
| `value` | Return value (on success) |
| `error` | Error message (on failure) |
| `duration_ms` | Execution time in milliseconds |

---

### RubyPi::Agent

The Agent implements a **think-act-observe** loop: send messages to the LLM, execute any tool calls it requests, feed results back, and repeat until the model produces a final text response or hits the iteration limit.

#### Creating an Agent

```ruby
agent = RubyPi::Agent.new(
  system_prompt: "You are a helpful assistant.",  # required: system-level instruction
  model: model,                        # required: an LLM provider instance
  tools: registry,                     # optional: a Tools::Registry
  max_iterations: 10,                  # optional: loop safety limit (default: 10)
  compaction: compaction,              # optional: Context::Compaction instance
  transform_context: transform,        # optional: context transform callable
  before_tool_call: ->(tc) { },        # optional: pre-tool-execution hook
  after_tool_call: ->(tc, r) { },      # optional: post-tool-execution hook
  user_data: {}                        # optional: arbitrary data for transforms/extensions
)

# Extensions are registered after construction via `use` (takes a CLASS, not an instance):
agent.use(MetricsExtension)
```

#### Running the Agent

```ruby
# Single run
result = agent.run("What is the weather in Tokyo?")
result.content           # => "The weather in Tokyo is..."
result.messages          # => full conversation history
result.tool_calls_made   # => [{ name: "get_weather", ... }, ...]
result.turns             # => 2

# Continue the conversation
result2 = agent.continue("And in London?")
```

#### Event Subscriptions

Subscribe to lifecycle events for logging, monitoring, or custom behavior:

```ruby
agent.on(:turn_start)          { |e| puts "Turn #{e[:turn]} starting" }
agent.on(:turn_end)            { |e| puts "Turn #{e[:turn]} ended" }
agent.on(:text_delta)          { |e| print e[:content] }
agent.on(:tool_execution_start){ |e| puts "Calling #{e[:tool_name]}" }
agent.on(:tool_execution_end)  { |e| puts "#{e[:tool_name]} => #{e[:result].value}" }
# Note: before_tool_call and after_tool_call are constructor hooks (Procs),
# not subscribable events. Use the constructor kwargs instead:
#   before_tool_call: ->(tc) { puts "About to call #{tc.name}" }
#   after_tool_call: ->(tc, result) { puts "Finished #{tc.name}" }
agent.on(:agent_end)           { |e| puts "Agent finished" }
agent.on(:error)               { |e| warn "Error: #{e[:error].message}" }
```

---

### RubyPi::Context

Utilities for managing conversation context, especially in long-running or multi-turn agents.

#### Compaction

Prevent unbounded context growth by compacting older messages:

```ruby
compaction = RubyPi::Context::Compaction.new(
  summary_model: summary_model,  # required: LLM provider for generating summaries
  max_tokens: 4000,              # optional: trigger compaction above this threshold (default: 8000)
  preserve_last_n: 4             # optional: always keep the last N messages (default: 4)
)

agent = RubyPi::Agent.new(
  system_prompt: "You are helpful.",
  model: model,
  compaction: compaction
)
```

#### Transform

Apply arbitrary transformations to the message list before each LLM call:

```ruby
# Transform is a module with factory methods, not a class.
# Use the built-in transforms or compose your own:
transform = RubyPi::Context::Transform.compose(
  RubyPi::Context::Transform.inject_datetime,
  RubyPi::Context::Transform.inject_user_preferences { |state| state.user_data[:prefs] }
)

# Or write a custom transform as a lambda that receives the Agent::State:
custom_transform = ->(state) do
  state.system_prompt += "\n\nAdditional context here."
end

agent = RubyPi::Agent.new(
  system_prompt: "You are a helpful Ruby assistant.",
  model: model,
  transform_context: transform
)
```

---

### RubyPi::Extensions

Extensions hook into the agent's event system to add cross-cutting behavior (logging, metrics, guardrails) without modifying the core loop.

#### Defining an Extension

```ruby
class MetricsExtension < RubyPi::Extensions::Base
  on_event :turn_start do |event|
    @turn_timer = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  on_event :turn_end do |event|
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @turn_timer
    puts "Turn #{event[:turn]} took #{elapsed.round(2)}s"
  end

  on_event :agent_end do |event|
    puts "Agent completed in #{event[:result].turns} turns"
  end
end
```

#### Registering Extensions

```ruby
agent = RubyPi::Agent.new(
  system_prompt: "You are helpful.",
  model: model
)

# Register extensions using `use` — pass the CLASS, not an instance:
agent.use(MetricsExtension)
agent.use(AnotherExtension)
```

Extensions receive the same event payloads as `agent.on(...)` callbacks. Use them when you want reusable, self-contained behavior modules.

---

## Configuration

All settings are managed through a global configuration block:

```ruby
RubyPi.configure do |config|
  # API keys
  config.gemini_api_key    = ENV["GEMINI_API_KEY"]
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.openai_api_key    = ENV["OPENAI_API_KEY"]

  # Retry behavior
  config.max_retries      = 3      # retries for transient errors
  config.retry_base_delay = 1.0    # base delay (seconds) for exponential backoff
  config.retry_max_delay  = 30.0   # cap on retry delay

  # Timeouts
  config.request_timeout = 120     # HTTP request timeout (seconds)
  config.open_timeout    = 10      # connection open timeout (seconds)

  # Default models (used when you omit the model name)
  config.default_gemini_model    = "gemini-2.0-flash"
  config.default_anthropic_model = "claude-sonnet-4-20250514"
  config.default_openai_model    = "gpt-4o"

  # Logging
  config.logger = Logger.new($stdout)
end
```

You can also reset configuration to defaults:

```ruby
RubyPi.reset_configuration!
```

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Write tests for your changes
4. Ensure all tests pass: `bundle exec rspec`
5. Commit your changes (`git commit -am 'Add my feature'`)
6. Push to the branch (`git push origin feature/my-feature`)
7. Open a Pull Request

Please follow the existing code style and include tests for any new functionality.

---

## License

Released under the [MIT License](LICENSE).
