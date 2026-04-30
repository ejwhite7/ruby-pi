# RubyPi Adversarial Code Review — v3

Re-review of branch `fix/review-remediation` at `eace165` ("fix: address 12 defects from adversarial review round 2"). Most v2 findings are addressed. This pass focuses on:

1. Defects in the new commit's fixes themselves.
2. v2 issues that the commit did not fully resolve.
3. New surface area created by the changes.

File:line references are exact against `HEAD` of the branch.

---

## Critical — fixes that don't actually fix the problem

### 1. OpenAI and Gemini streaming `error_body` is captured but never passed to `handle_error_response`
The commit message claims "all providers detect HTTP error status in on_data streaming callbacks. Accumulate error response bodies separately so ApiError contains the full error body even when streaming consumed the response." Only the Anthropic side actually does the second half.

Anthropic does it correctly (`anthropic.rb:432-437`):
```ruby
unless response.success?
  error_response = response
  error_body_str = error_body.empty? ? response.body : error_body
  handle_error_response(error_response, override_body: error_body_str)
end
```

Gemini (`gemini.rb:313`) and OpenAI (`openai.rb:394`) both do:
```ruby
handle_error_response(response) unless response.success?
```

— with no `override_body:`. The accumulated `error_body` buffer is allocated, populated, and then thrown away. The `ApiError` for streaming Gemini/OpenAI failures still carries an empty body. The fix is half-applied; tests didn't catch it because none assert on `ApiError#response_body` content for streaming responses.

### 2. Compaction's `role: :assistant` fix still produces consecutive-same-role sequences in real agent flows
The fix changes the summary role from `:user` to `:assistant` and the spec verifies "no two consecutive messages share the same role" (`spec/ruby_pi/context/compaction_spec.rb:138-146`). But the test fixture (`compaction_spec.rb:90-96`) is `[user, assistant, user, assistant]` — preserved is always `[user, assistant]`, so prepending an `:assistant` summary gives `[assistant, user, assistant]`. Looks fine.

In real agent flows, the message tail often is `[..., assistant_with_tool_calls, tool_result(s), assistant]`, but it can also legitimately end with `[..., tool, assistant]` or `[..., assistant, user]`. With `preserve_last_n: 2`, the preserved slice can be `[assistant, user]`. Compacted output: `[assistant_summary, assistant, user]` — **consecutive assistants**, which Anthropic rejects (the very condition the fix exists to avoid).

The right fix is structural: choose the summary role based on what's about to follow, e.g.:
```ruby
first_preserved_role = preserved.first&.dig(:role)
summary_role = first_preserved_role == :assistant ? :user : :assistant
```
Or, group the summary into the first message rather than prepending. The current implementation only works for sequences that happen to start with a non-assistant message.

### 3. The new `:fallback_start` StreamEvent is silently dropped by the agent loop
`fallback.rb:169-173` emits a `:fallback_start` `StreamEvent` so consumers can clear partial output before fallback streams. But the `Loop#think` block (`agent/loop.rb:156-166`) only handles two event types:

```ruby
if event.text_delta?
  ...
elsif event.tool_call_delta?
  ...
end
```

A `:fallback_start` event hits neither branch and is discarded. The agent's `text_delta` event subscribers (the documented way to consume streaming output in the gem's primary use case) never see the signal. So the fix only works for users who call `provider.complete(...) { |event| ... }` directly, not for users of `RubyPi::Agent`. For agent users, the v2 problem (consumer sees `partial-from-primary + complete-from-fallback`) is still there.

To fix: emit a corresponding agent-level event (e.g., `:provider_fallback`) in the loop's stream block, or surface fallback_start through the existing event bus.

### 4. `Agent::Core#config:` is still decorative — fix #3 only works at the model factory
`base_provider.rb:51-55` correctly accepts `config:` and uses it. `RubyPi::LLM.model(provider, name, **options)` (`lib/ruby_pi.rb:99`) forwards `**options` to provider constructors, so `RubyPi::LLM.model(:openai, "gpt-4o", config: cfg)` does correctly thread `cfg` through.

But `Agent::Core` accepts `config: nil` (`agent/core.rb:84`), stores it in `@config` (line 101), exposes `effective_config` (lines 168-170) — and **nothing in the agent ever reads `effective_config`**. The model passed to the agent has already been constructed before `Agent.new`; passing `config:` to `Agent.new` cannot retroactively change the model's behavior.

The CHANGELOG entry says: "The `config:` kwarg on `Agent::Core` now flows through to provider construction via `BaseProvider#initialize(config:)`." This is false — there is no flow from `Agent::Core` to provider construction; the user must pass `config:` to the model factory directly. Setting it on `Agent.new` is a no-op masquerading as a feature.

Either:
- Remove `config:` from `Agent.new` entirely (it's misleading).
- Or have `Agent.new` rebuild the model when given a `config:` (changes the API contract).
- Or have `Agent.new` validate that `model.config == agent.config` and raise on mismatch.

The current state is the worst of all worlds: silently does nothing.

---

## Major — Documentation accuracy

### 5. CHANGELOG references nonexistent `BufferedStreamProxy` class
`CHANGELOG.md` for `[0.1.4]` contains:
- `**`BufferedStreamProxy` blocking happy path**: ...`
- `**`BufferedStreamProxy` for fallback + streaming` (in the "previously addressed" section)

`grep -r BufferedStreamProxy lib/ spec/` finds nothing. There is no such class. The buffering logic is inline in `Fallback#perform_complete_with_streaming_fallback`. The changelog is fictional in the v0.1.4 entry on this point. Either rename the entry or remove the reference.

### 6. `:fallback_start` StreamEvent is undocumented for users
The new event type exists in `StreamEvent::VALID_TYPES` (`stream_event.rb:28`) and is emitted on fallback. But:
- No `#fallback_start?` predicate is defined (compare `text_delta?`, `tool_call_delta?`, `done?` at lines 56-72).
- `README.md` example streaming code (lines 124-137) doesn't mention it.
- Data payload schema (`{ failed_provider:, error:, fallback_provider: }`) is not documented anywhere except the source.

Users who add a `case event.type when :fallback_start` clause will work; users who use `event.text_delta?` won't observe it.

### 7. `parse_sse_events` removal didn't update the "Adding a new LLM provider" guide
`CLAUDE.md:148-152` (Adding a New LLM Provider) still says:

> 4. Use `build_connection(base_url:, headers:)` for Faraday setup
> 5. Use `handle_error_response(response)` to raise typed errors
> 6. **Use `parse_sse_events(body) { |data| ... }` for streaming**

Step 6 is now wrong — `parse_sse_events` was removed. New provider authors following the guide will reference a deleted method.

### 8. `Agent::Core` docstring example shows stale `before_tool_call`/`after_tool_call` block signature
`agent/core.rb:33-34`:
```
#     before_tool_call: ->(tc) { puts "Calling #{tc.name}" },
#     after_tool_call: ->(tc, r) { puts "Done: #{r.success?}" }
```
This matches code (`loop.rb:209, 220`). OK actually that's consistent. Withdraw — not an issue.

---

## Major — Issues from v2 that are still unresolved

### 9. Worker thread leak in `Executor`
`executor.rb:206-219` documents that `worker.join(@timeout)` returning nil leaves the worker thread running, with no termination mechanism. Concurrent::Future cancellation is similarly cooperative only. Each timeout produces an orphaned thread. Under any sustained timeout pressure, threads accumulate and the process eventually OOMs. Documented but unmitigated.

### 10. Compaction summary as `:assistant` is semantically dishonest
The model reads its own assistant turn `[Conversation Summary]\n…` as if IT had said that. It didn't — the system inserted it. Future turns may treat the summary as something the model "remembers saying" and reason from it. This may be fine in practice but it's worth noting that the v2 `:user` choice was at least semantically honest ("here's a summary from the user"), while `:assistant` lies about authorship to satisfy alternation.

### 11. `Fallback#provider_name` returns `:fallback`
`fallback.rb:60-62` still returns the constant. Errors and logs from BaseProvider use `provider_name` for messages (e.g., `base_provider.rb:148`); when retries log `[RubyPi::fallback] Retry 1/3 ...`, the underlying provider that's actually retrying is hidden. Observability gap.

### 12. `response_status` racing the first chunk
`gemini.rb:245`, `anthropic.rb:387`, `openai.rb:312`: `response_status ||= env&.status`. On all current Faraday adapters this works because status is set before on_data fires for the first chunk. But the `||=` means the variable is only read if it's still nil — fine. The risk: if status is set AFTER on_data starts (theoretically possible with HTTP/2 + Trailers, or some proxies), early chunks would be parsed as SSE and silently fail to parse. Edge case but the cost is silently corrupted error reporting.

### 13. `arguments_fragment` for OpenAI emits accumulated name in every event
`openai.rb:382-387`:
```ruby
block.call(StreamEvent.new(type: :tool_call_delta, data: {
  index: index,
  id: acc[:id],
  name: acc[:name],   # <- accumulated, not delta
  arguments_fragment: tc_delta.dig("function", "arguments") || ""
}))
```
`acc[:name]` is the running concatenation. So consumers get `name: "g"`, `name: "ge"`, `name: "get"`, ... in successive events. The "delta" naming suggests the delta only, but the field is the full accumulated name. Probably intentional but inconsistent with `arguments_fragment` (which is the delta). Document or rename.

### 14. `result_content = result.success? ? JSON.generate(result.value) : "Error: #{result.error}"`
`agent/loop.rb:235`. If `result.value` contains a non-JSON-serializable object (Time, Date, custom classes without `to_json`), `JSON.generate` raises. The error is then caught by the outer rescue in `Loop#run` and the agent fails entirely. Tools returning native Ruby objects with timestamps are common; this is a footgun. At minimum: rescue `JSON::GeneratorError` and fall back to `result.value.to_s`.

### 15. `tool_call.arguments` recorded in `tool_calls_made` is string-keyed, but the tool block received symbol-keyed
`agent/loop.rb:228-232` records `arguments: tc.arguments` — the raw JSON-parsed string-keyed hash. The Executor's `deep_symbolize_keys` (`executor.rb:174`) creates a copy used to invoke the tool, but `tc.arguments` is unchanged. So `result.tool_calls_made[i][:arguments]["x"]` works, but `result.tool_calls_made[i][:arguments][:x]` returns nil — opposite of how the tool block accessed them. Inconsistent contract.

### 16. `Result#to_s` (aliased as `inspect`) can dump a large `messages` array
`agent/result.rb:127-135`. `parts` only includes status/turns/tool count/error/truncated, but the inspect of a Result might be called somewhere by RSpec failure messages, debugger, or pry that expands the full object. Not an immediate bug but worth noting that long conversations make Result objects expensive to print.

### 17. `Loop#act` builds Executor on every act phase (loop.rb:196-200)
A new `Tools::Executor` is constructed for every think-act-observe cycle. The Executor is stateless past initialization, but allocating each turn means the per-tool timeout / mode is fixed at agent construction (`@execution_mode`, `@tool_timeout`). Future enhancement: tool-specific timeout (e.g., a slow `db_query` tool). Currently every tool gets the same global timeout. Minor.

---

## Minor — hygiene

### 18. `process_anthropic_stream_event` returns a 3-key hash on every event
`anthropic.rb:577-580`. Allocates a new hash on every SSE event (potentially many per request). Negligible but `Struct.new(:current_tool_call, :current_tool_json, :finish_reason)` would be cheaper, or just inline the `case` block back into the proc since the helper is only called from there.

### 19. Anthropic streaming has TWO calls to `process_anthropic_stream_event` (lines 418 and 451)
The second one (lines 440-458) processes "any remaining data in the buffer after the connection closes". With on_data, the only remaining data would be a partial line — but partial lines are skipped (`next unless line.start_with?("data: ")` — only complete lines pass). So this block only fires when the buffer happens to contain a complete `data: ...\n` that wasn't processed inside `on_data`. Given the on_data loop processes lines until `index("\n")` returns nil, this block runs only when the connection closes between the last `\n` and the next chunk — possible but rare. Code is correct, just complex; could be simplified.

### 20. CHANGELOG falsely lists "Per-agent configuration support (`config:` kwarg)" twice
`CHANGELOG.md`'s `[0.1.4]` section lists per-agent config in BOTH "New Defects" and "Previously Addressed" — once as new (line 14) and once as old (line 35). Pick one.

### 21. `compaction_spec.rb:138-146` test masks the bug it claims to test
The "does not produce consecutive messages" test only checks the compacted output's INTERNAL alternation, but the fixture's preserved messages are `[user, assistant]` so the test can't fail. Add cases where preserved is `[assistant, user]`, `[tool, assistant]`, etc. The test as written gives false confidence.

### 22. `RubyPi::LLM::Fallback` constructor doesn't accept `config:` explicitly
`fallback.rb:44-48`: `initialize(primary:, fallback:, **options)`. `options` flows to `super(**options)` which goes to `BaseProvider#initialize(config: ...)`. So `Fallback.new(primary:, fallback:, config: cfg)` would work — but Fallback doesn't actually use config (it uses primary/fallback directly). Yet it inherits the `@config` ivar from BaseProvider. This means a Fallback with one config and underlying providers with different configs is silently inconsistent. Either pull `config:` out of `**options` and explicitly pass to inner providers, or document that Fallback config is irrelevant.

### 23. `Compaction#summarize` calls `@summary_model.complete(... stream: false)` with no block
`compaction.rb:128-143`. Provider's `perform_complete` checks `if stream && block_given?`, so non-streaming path runs. But `BaseProvider#complete` includes its own retry. If the summary model is the same instance as the agent's main model AND that model is a Fallback, the retry behavior compounds with anything happening above. Compaction therefore can drag agent latency by an unbounded amount on a flaky summary model. Worth a configurable timeout.

---

## Verification — items confirmed fixed in this commit

For Codex / reviewers spot-checking the commit:

- ✓ Anthropic `\#{...}` literal — now `#{...}` at `anthropic.rb:543-545`.
- ✓ `@_stream_*` ivars — replaced with hash returned from helper at `anthropic.rb:577-580` and read back at lines 422-424, 455-457.
- ✓ Anthropic streaming captures error_body and uses `override_body:` (`anthropic.rb:436`).
- ✓ Compaction summary now `:assistant` (`compaction.rb:101`).
- ✓ OpenAI fail-fast for missing `tool_call_id` (`openai.rb:136-143`) and `id` (`openai.rb:197-203`). Matches Anthropic's pattern.
- ✓ Gemini streaming reads `candidate["finishReason"]` (`gemini.rb:296-298`); falls back to "stop" only if missing (line 322).
- ✓ README event keys — `e[:turn]`, `event[:result].turns` (search for `:iteration` in README.md returns no hits in code blocks).
- ✓ `parse_sse_events` removed from `BaseProvider`.
- ✓ `faraday-net_http < 3.4` removed from gemspec and Gemfile.
- ✓ Fallback no longer buffers happy path (`fallback.rb:152-157`).
- ✓ `BaseProvider#initialize(config:)` accepts and uses per-agent config (`base_provider.rb:51-55`); providers correctly use `@config` instead of `RubyPi.configuration`.
- ✓ `handle_error_response` accepts `override_body:` (`base_provider.rb:192-203`).

---

## Suggested priority

1. **#1** (Gemini/OpenAI streaming error_body unused) — apply Anthropic's `override_body:` pattern in two more places. Five-minute fix.
2. **#3** (`fallback_start` not propagated to agent users) — add a corresponding agent event or extend the loop's event-handling block. Without this, the fix only helps non-Agent users — a small minority of the gem's surface.
3. **#2** (compaction consecutive-role bug under realistic patterns) — choose summary role based on next preserved role, and add test fixtures with all four orderings.
4. **#4** (`Agent::Core#config:` does nothing) — remove the parameter, OR document that it's information-only and the user must pass `config:` to the model factory separately, OR validate consistency.
5. **#5, #7** (CHANGELOG/CLAUDE.md errors) — easy doc fixes.
6. **#14** (`JSON.generate` on tool result can crash) — add `JSON::GeneratorError` rescue in Loop#act.
7. **#15** (string- vs symbol-keyed inconsistency in `tool_calls_made`) — settle on one shape.

Items #6, #9-13, #16-23 are real but not blockers for a 0.1.4 release.

---

## Bottom line

The fix commit `eace165` resolves the majority of v2 findings. The remaining issues are concentrated in three classes:

- **Incomplete application of a fix pattern across all providers** (#1, #4) — copy-paste asymmetry between Anthropic and the other two.
- **Behavior changes that didn't propagate to the agent layer** (#3) — `:fallback_start` is invented and emitted but the gem's primary consumer doesn't observe it.
- **Test fixtures that don't exercise the failure conditions the fixes target** (#2 vs #21) — the spec passes, the bug remains, with a false sense of confidence.

These are the kinds of issues that survive code review but get caught by integration testing or production traffic. None are show-stoppers; all are tractable.
