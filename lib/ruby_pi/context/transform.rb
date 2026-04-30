# frozen_string_literal: true

# lib/ruby_pi/context/transform.rb
#
# RubyPi::Context::Transform — Composable helpers for mutating agent state
# before each LLM call.
#
# Transforms are callables (lambdas/procs) that receive the Agent::State and
# modify it in place — typically appending context to the system prompt. This
# module provides factory methods for common transform patterns (datetime
# injection, user preferences, workspace context) and a `compose` method for
# chaining multiple transforms into a single callable.
#
# IDEMPOTENCY: Each injection method uses unique marker delimiters
# (e.g., <!-- RUBYPI_DATETIME_START --> ... <!-- RUBYPI_DATETIME_END -->) to
# wrap injected content. Before re-adding, the transform strips any existing
# injection matching its markers. This prevents the system prompt from
# accumulating duplicate injections across multiple LLM calls in a loop.

module RubyPi
  module Context
    # Factory methods for building transform_context callables. Each method
    # returns a Proc that accepts an Agent::State and mutates it. Use
    # `compose` to chain multiple transforms.
    #
    # @example Composing transforms
    #   transform = RubyPi::Context::Transform.compose(
    #     RubyPi::Context::Transform.inject_datetime,
    #     RubyPi::Context::Transform.inject_user_preferences { |state| state.user_data[:prefs] }
    #   )
    #   agent = RubyPi::Agent.new(transform_context: transform, ...)
    module Transform
      # Marker delimiters for idempotent injection. Each injection type has
      # unique start/end markers so they can be independently stripped and
      # re-added without affecting each other.
      DATETIME_START_MARKER  = "<!-- RUBYPI_DATETIME_START -->"
      DATETIME_END_MARKER    = "<!-- RUBYPI_DATETIME_END -->"
      PREFS_START_MARKER     = "<!-- RUBYPI_PREFS_START -->"
      PREFS_END_MARKER       = "<!-- RUBYPI_PREFS_END -->"
      WORKSPACE_START_MARKER = "<!-- RUBYPI_WORKSPACE_START -->"
      WORKSPACE_END_MARKER   = "<!-- RUBYPI_WORKSPACE_END -->"

      class << self
        # Chains multiple transform callables into a single callable that
        # executes them in order. Each transform receives the same State
        # object and can mutate it freely.
        #
        # @param transforms [Array<Proc>] transform callables to chain
        # @return [Proc] a single callable that runs all transforms in sequence
        #
        # @example
        #   combined = Transform.compose(transform_a, transform_b, transform_c)
        #   combined.call(state) # runs a, then b, then c
        def compose(*transforms)
          ->(state) do
            transforms.each { |t| t.call(state) }
          end
        end

        # Returns a transform that appends the current date and time to the
        # system prompt. Useful for giving the LLM temporal awareness.
        #
        # This injection is IDEMPOTENT: it strips any existing datetime
        # injection (identified by markers) before re-adding, so calling it
        # N times in a loop produces exactly one datetime block.
        #
        # @return [Proc] transform callable
        #
        # @example
        #   transform = Transform.inject_datetime
        #   # Appends: "\n\nCurrent date and time: 2025-01-15 14:30:00 UTC"
        def inject_datetime
          ->(state) do
            timestamp = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S UTC")

            # Strip any existing datetime injection before re-adding.
            # This makes the transform idempotent — calling it multiple times
            # across loop iterations does not accumulate duplicate timestamps.
            state.system_prompt = strip_between_markers(
              state.system_prompt,
              DATETIME_START_MARKER,
              DATETIME_END_MARKER
            )

            state.system_prompt += "\n\n#{DATETIME_START_MARKER}\nCurrent date and time: #{timestamp}\n#{DATETIME_END_MARKER}"
          end
        end

        # Returns a transform that appends user preferences to the system
        # prompt. The block is called with the state and should return a
        # string or hash of preferences. If nil is returned, nothing is
        # appended.
        #
        # This injection is IDEMPOTENT: existing preferences are stripped
        # before re-adding.
        #
        # @yield [state] block that extracts preferences from the state
        # @yieldparam state [RubyPi::Agent::State] the current agent state
        # @yieldreturn [String, Hash, nil] preferences to inject
        # @return [Proc] transform callable
        #
        # @example
        #   transform = Transform.inject_user_preferences { |s| s.user_data[:prefs] }
        def inject_user_preferences(&block)
          ->(state) do
            preferences = block.call(state)
            # Always strip existing preferences injection first for idempotency
            state.system_prompt = strip_between_markers(
              state.system_prompt,
              PREFS_START_MARKER,
              PREFS_END_MARKER
            )
            return if preferences.nil?

            prefs_text = preferences.is_a?(Hash) ? format_hash(preferences) : preferences.to_s
            state.system_prompt += "\n\n#{PREFS_START_MARKER}\n[User Preferences]\n#{prefs_text}\n#{PREFS_END_MARKER}"
          end
        end

        # Returns a transform that appends workspace context to the system
        # prompt. The block is called with the state and should return
        # contextual information about the current workspace/project.
        #
        # This injection is IDEMPOTENT: existing workspace context is stripped
        # before re-adding.
        #
        # @yield [state] block that extracts workspace context from the state
        # @yieldparam state [RubyPi::Agent::State] the current agent state
        # @yieldreturn [String, Hash, nil] workspace context to inject
        # @return [Proc] transform callable
        #
        # @example
        #   transform = Transform.inject_workspace_context { |s| s.user_data[:workspace] }
        def inject_workspace_context(&block)
          ->(state) do
            context = block.call(state)
            # Always strip existing workspace injection first for idempotency
            state.system_prompt = strip_between_markers(
              state.system_prompt,
              WORKSPACE_START_MARKER,
              WORKSPACE_END_MARKER
            )
            return if context.nil?

            ctx_text = context.is_a?(Hash) ? format_hash(context) : context.to_s
            state.system_prompt += "\n\n#{WORKSPACE_START_MARKER}\n[Workspace Context]\n#{ctx_text}\n#{WORKSPACE_END_MARKER}"
          end
        end

        private

        # Strips content between (and including) the given start and end
        # markers from the text. Used to remove a previous injection before
        # re-adding it, ensuring idempotency.
        #
        # @param text [String] the text to strip markers from
        # @param start_marker [String] the opening marker
        # @param end_marker [String] the closing marker
        # @return [String] text with the marked section removed
        def strip_between_markers(text, start_marker, end_marker)
          # Use a regex that matches the markers and everything between them,
          # including any leading whitespace (newlines) before the start marker.
          escaped_start = Regexp.escape(start_marker)
          escaped_end = Regexp.escape(end_marker)
          text.gsub(/\s*#{escaped_start}.*?#{escaped_end}/m, "")
        end

        # Formats a hash into a human-readable key-value string for injection
        # into the system prompt.
        #
        # @param hash [Hash] the data to format
        # @return [String] formatted key-value pairs
        def format_hash(hash)
          hash.map { |k, v| "- #{k}: #{v}" }.join("\n")
        end
      end
    end
  end
end
