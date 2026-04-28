# frozen_string_literal: true

# lib/ruby_pi/agent/state.rb
#
# RubyPi::Agent::State — Mutable container for all agent runtime state.
#
# State holds the conversation history, system prompt, model reference, tool
# registry, iteration counter, lifecycle hooks (transform_context, before_tool_call,
# after_tool_call), and an arbitrary user_data hash for extension-provided context.
# The agent loop reads and mutates State as it progresses through think-act-observe
# cycles.

module RubyPi
  module Agent
    # Mutable state object threaded through the agent loop. Encapsulates the
    # full conversation history, configuration, and hook callables so that
    # the loop, compaction, and transforms all operate on a single shared
    # object.
    #
    # @example Creating and using state
    #   state = RubyPi::Agent::State.new(
    #     system_prompt: "You are helpful.",
    #     model: RubyPi::LLM.model(:gemini, "gemini-2.0-flash"),
    #     tools: registry,
    #     max_iterations: 10
    #   )
    #   state.add_message(role: :user, content: "Hi!")
    #   state.messages  # => [{ role: :user, content: "Hi!" }]
    class State
      # @return [String] the system prompt prepended to every LLM call
      attr_accessor :system_prompt

      # @return [RubyPi::LLM::BaseProvider] the LLM provider instance
      attr_reader :model

      # @return [RubyPi::Tools::Registry] the registry of available tools
      attr_reader :tools

      # @return [Integer] maximum think-act-observe iterations before halting
      attr_reader :max_iterations

      # @return [Proc, nil] callable invoked with state before each LLM call
      #   to transform context (system prompt, messages)
      attr_accessor :transform_context

      # @return [Proc, nil] callable invoked before each tool call; receives
      #   the RubyPi::LLM::ToolCall
      attr_accessor :before_tool_call

      # @return [Proc, nil] callable invoked after each tool call; receives
      #   the ToolCall and the RubyPi::Tools::Result
      attr_accessor :after_tool_call

      # @return [Hash] arbitrary user-provided data accessible by transforms
      #   and extensions
      attr_accessor :user_data

      # Creates a new State instance with the given configuration.
      #
      # @param system_prompt [String] the system-level instruction prompt
      # @param model [RubyPi::LLM::BaseProvider] the LLM provider to use
      # @param tools [RubyPi::Tools::Registry, nil] tool registry (nil for no tools)
      # @param messages [Array<Hash>] initial conversation history
      # @param max_iterations [Integer] max think-act-observe cycles (default: 10)
      # @param transform_context [Proc, nil] context transform hook
      # @param before_tool_call [Proc, nil] pre-tool-execution hook
      # @param after_tool_call [Proc, nil] post-tool-execution hook
      # @param user_data [Hash] arbitrary data bag for extensions/transforms
      def initialize(
        system_prompt:,
        model:,
        tools: nil,
        messages: [],
        max_iterations: 10,
        transform_context: nil,
        before_tool_call: nil,
        after_tool_call: nil,
        user_data: {}
      )
        @system_prompt = system_prompt
        @model = model
        @tools = tools
        @messages = Array(messages).dup
        @max_iterations = max_iterations
        @transform_context = transform_context
        @before_tool_call = before_tool_call
        @after_tool_call = after_tool_call
        @user_data = user_data
        @iteration = 0
      end

      # Appends a message to the conversation history.
      #
      # @param role [Symbol, String] the message role (:user, :assistant, :system, :tool)
      # @param content [String, nil] the text content of the message
      # @param options [Hash] additional fields (e.g., :tool_call_id, :tool_calls)
      # @return [Array<Hash>] the updated messages array
      def add_message(role:, content: nil, **options)
        message = { role: role.to_sym, content: content }.merge(options)
        @messages << message
        @messages
      end

      # Returns a frozen copy of the conversation history. Callers cannot
      # accidentally mutate the internal array through this reference.
      #
      # @return [Array<Hash>] the full conversation history
      def messages
        @messages.dup.freeze
      end

      # Replaces the entire conversation history. Used by compaction to swap
      # in a shortened message array.
      #
      # @param new_messages [Array<Hash>] the replacement message array
      # @return [Array<Hash>] the new messages array
      def messages=(new_messages)
        @messages = Array(new_messages).dup
      end

      # Returns the current iteration count (number of completed think-act-observe
      # cycles).
      #
      # @return [Integer] the iteration count
      def iteration
        @iteration
      end

      # Increments the iteration counter by one. Called by the agent loop at
      # the end of each think-act-observe cycle.
      #
      # @return [Integer] the new iteration count
      def increment_iteration!
        @iteration += 1
      end

      # Returns true if the iteration count has reached or exceeded max_iterations.
      #
      # @return [Boolean]
      def max_iterations_reached?
        @iteration >= @max_iterations
      end

      # Provides a human-readable summary of the current state for debugging.
      #
      # @return [String]
      def inspect
        "#<RubyPi::Agent::State " \
          "iteration=#{@iteration}/#{@max_iterations} " \
          "messages=#{@messages.size} " \
          "tools=#{@tools&.size || 0}>"
      end
    end
  end
end
