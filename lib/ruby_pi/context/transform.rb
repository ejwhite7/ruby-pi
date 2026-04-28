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
        # @return [Proc] transform callable
        #
        # @example
        #   transform = Transform.inject_datetime
        #   # Appends: "\n\nCurrent date and time: 2025-01-15 14:30:00 UTC"
        def inject_datetime
          ->(state) do
            timestamp = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
            state.system_prompt += "\n\nCurrent date and time: #{timestamp}"
          end
        end

        # Returns a transform that appends user preferences to the system
        # prompt. The block is called with the state and should return a
        # string or hash of preferences. If nil is returned, nothing is
        # appended.
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
            return if preferences.nil?

            prefs_text = preferences.is_a?(Hash) ? format_hash(preferences) : preferences.to_s
            state.system_prompt += "\n\n[User Preferences]\n#{prefs_text}"
          end
        end

        # Returns a transform that appends workspace context to the system
        # prompt. The block is called with the state and should return
        # contextual information about the current workspace/project.
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
            return if context.nil?

            ctx_text = context.is_a?(Hash) ? format_hash(context) : context.to_s
            state.system_prompt += "\n\n[Workspace Context]\n#{ctx_text}"
          end
        end

        private

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
