# frozen_string_literal: true

# lib/ruby_pi/agent/core.rb
#
# RubyPi::Agent::Core — The main Agent class and public entry point.
#
# Core orchestrates the full agent lifecycle: it manages state, includes the
# EventEmitter for event subscriptions, delegates to Loop for the think-act-observe
# cycle, and supports extensions via the `use` method. This is the class users
# instantiate and interact with when building agentic workflows.
#
# Usage:
#   agent = RubyPi::Agent::Core.new(
#     system_prompt: "You are a helpful assistant.",
#     model: RubyPi::LLM.model(:gemini, "gemini-2.0-flash"),
#     tools: registry
#   )
#   agent.on(:text_delta) { |d| print d[:content] }
#   result = agent.run("Tell me about Ruby")

module RubyPi
  module Agent
    # The main agent class. Wraps State, Loop, and EventEmitter into a cohesive
    # interface for running agentic LLM interactions with tool use, streaming,
    # and lifecycle hooks.
    #
    # @example Full lifecycle
    #   agent = RubyPi::Agent::Core.new(
    #     system_prompt: "You are Olli, an AI assistant.",
    #     model: RubyPi::LLM.model(:gemini, "gemini-2.0-flash"),
    #     tools: registry,
    #     max_iterations: 10,
    #     before_tool_call: ->(tc) { puts "Calling #{tc.name}" },
    #     after_tool_call: ->(tc, r) { puts "Done: #{r.success?}" }
    #   )
    #
    #   agent.on(:text_delta) { |d| stream.write(d[:content]) }
    #   agent.on(:agent_end) { |_| stream.close }
    #
    #   result = agent.run("Create a LinkedIn post")
    #   result = agent.continue("Make it shorter")
    class Core
      include EventEmitter

      # @return [RubyPi::Agent::State] the agent's mutable state
      attr_reader :state

      # @return [Array<Class>] registered extension classes for introspection
      attr_reader :extensions

      # @return [RubyPi::Configuration, nil] per-agent configuration override
      #   (nil means use global RubyPi.configuration)
      attr_reader :config

      # Creates a new Agent instance.
      #
      # @param system_prompt [String] the system-level instruction prompt
      # @param model [RubyPi::LLM::BaseProvider] the LLM provider instance
      # @param tools [RubyPi::Tools::Registry, nil] tool registry
      # @param messages [Array<Hash>] initial conversation history
      # @param max_iterations [Integer] max think-act-observe cycles (default: 10)
      # @param transform_context [Proc, nil] context transform hook
      # @param before_tool_call [Proc, nil] pre-tool-execution hook
      # @param after_tool_call [Proc, nil] post-tool-execution hook
      # @param compaction [RubyPi::Context::Compaction, nil] compaction strategy
      # @param user_data [Hash] arbitrary data bag for transforms/extensions
      # @param config [RubyPi::Configuration, nil] optional per-agent config
      #   override. Falls back to global RubyPi.configuration if nil.
      # @param execution_mode [Symbol] tool execution mode (:parallel or :sequential,
      #   default: :parallel)
      # @param tool_timeout [Numeric] per-tool execution timeout in seconds
      #   (default: 30)
      def initialize(
        system_prompt:,
        model:,
        tools: nil,
        messages: [],
        max_iterations: 10,
        transform_context: nil,
        before_tool_call: nil,
        after_tool_call: nil,
        compaction: nil,
        user_data: {},
        config: nil,
        execution_mode: :parallel,
        tool_timeout: 30
      )
        @state = State.new(
          system_prompt: system_prompt,
          model: model,
          tools: tools,
          messages: messages,
          max_iterations: max_iterations,
          transform_context: transform_context,
          before_tool_call: before_tool_call,
          after_tool_call: after_tool_call,
          user_data: user_data
        )
        @compaction = compaction
        @extensions = []
        @config = config
        @execution_mode = execution_mode
        @tool_timeout = tool_timeout
      end

      # Runs the agent with an initial user prompt. Adds the prompt to the
      # conversation history, executes the think-act-observe loop, emits
      # :agent_end when done, and returns the result.
      #
      # Issue #16: Resets the iteration counter at the start of each run()
      # call using the encapsulated reset_iteration! method. Previously,
      # the counter was never reset on run(), so a second call to run()
      # on the same agent instance could immediately trip max_iterations_reached?.
      #
      # @param prompt [String] the user's initial message
      # @return [RubyPi::Agent::Result] the outcome of the agent run
      def run(prompt)
        @state.reset_iteration!
        @state.add_message(role: :user, content: prompt)
        execute_loop
      end

      # Continues the conversation with a follow-up user message. Preserves
      # the existing conversation history and appends the new prompt before
      # resuming the loop.
      #
      # Issue #16: Uses the encapsulated reset_iteration! method instead of
      # the old approach that bypassed encapsulation
      # and was fragile.
      #
      # @param prompt [String] the follow-up user message
      # @return [RubyPi::Agent::Result] the outcome of the continued run
      def continue(prompt)
        @state.reset_iteration!
        @state.add_message(role: :user, content: prompt)
        execute_loop
      end

      # Registers an extension with this agent. The extension's hooks are
      # automatically subscribed to the agent's events.
      #
      # @param extension_class [Class] a subclass of RubyPi::Extensions::Base
      # @return [void]
      # @raise [ArgumentError] if the argument is not a valid extension class
      def use(extension_class)
        unless extension_class.respond_to?(:hooks)
          raise ArgumentError,
                "Expected an extension class with a .hooks method, got #{extension_class.inspect}"
        end

        # Subscribe each hook to the corresponding event
        extension_class.hooks.each do |event, handlers|
          handlers.each do |handler|
            on(event) do |data|
              handler.call(data, self)
            end
          end
        end

        @extensions << extension_class
      end

      # Returns the effective configuration for this agent. If a per-agent
      # config was provided, returns that; otherwise falls back to the
      # global RubyPi.configuration.
      #
      # @return [RubyPi::Configuration] the active configuration
      def effective_config
        @config || RubyPi.configuration
      end

      private

      # Creates a Loop instance and executes it, emitting :agent_end when
      # the loop completes.
      #
      # @return [RubyPi::Agent::Result]
      def execute_loop
        loop_runner = Loop.new(
          state: @state,
          emitter: self,
          compaction: @compaction,
          execution_mode: @execution_mode,
          tool_timeout: @tool_timeout
        )

        result = loop_runner.run

        emit(:agent_end, result: result, success: result.success?)

        result
      end
    end
  end

  # Module-level convenience method for creating Agent instances without
  # referencing Agent::Core directly. Allows `RubyPi::Agent.new(...)`.
  module Agent
    class << self
      # Creates a new Agent::Core instance. This is the recommended entry
      # point for building agents.
      #
      # @param args [Hash] constructor arguments forwarded to Agent::Core.new
      # @return [RubyPi::Agent::Core] a new agent instance
      #
      # @example
      #   agent = RubyPi::Agent.new(
      #     system_prompt: "You are helpful.",
      #     model: model,
      #     tools: registry
      #   )
      def new(**args)
        Core.new(**args)
      end
    end
  end
end
