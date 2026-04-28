# frozen_string_literal: true

# lib/ruby_pi/agent/loop.rb
#
# RubyPi::Agent::Loop — Implements the think-act-observe agentic cycle.
#
# The Loop drives the core agent behavior: calling the LLM (think), executing
# any tool calls (act), feeding results back into the conversation (observe),
# and repeating until the LLM signals completion or the max iteration limit
# is reached. It handles streaming, lifecycle events, compaction, and all
# pre/post tool call hooks.

module RubyPi
  module Agent
    # Executes the think-act-observe cycle against a given State, emitting
    # events through the provided EventEmitter-compatible emitter. Returns
    # an Agent::Result when the cycle terminates.
    #
    # The cycle:
    #   1. THINK — Call the LLM with current messages and tools. Apply
    #      transform_context if present. Emit :turn_start and stream
    #      :text_delta events.
    #   2. ACT — If the LLM returned tool calls, execute them via
    #      Tools::Executor. Fire before_tool_call / after_tool_call hooks
    #      and emit :tool_execution_start / :tool_execution_end events.
    #   3. OBSERVE — Append tool results to messages and loop back to THINK.
    #   4. DONE — Return when finish_reason == "stop" (no more tool calls)
    #      or max_iterations is reached.
    #
    # @example Running the loop directly
    #   loop = RubyPi::Agent::Loop.new(state: state, emitter: agent)
    #   result = loop.run
    class Loop
      # Creates a new Loop bound to the given state and event emitter.
      #
      # @param state [RubyPi::Agent::State] mutable agent state
      # @param emitter [#emit] object that responds to `emit(event, data)`
      # @param compaction [RubyPi::Context::Compaction, nil] optional compaction
      #   strategy for managing context window size
      def initialize(state:, emitter:, compaction: nil)
        @state = state
        @emitter = emitter
        @compaction = compaction
        @tool_calls_made = []
        @total_usage = { input_tokens: 0, output_tokens: 0 }
      end

      # Runs the think-act-observe cycle until completion or max iterations.
      # Returns an Agent::Result capturing the final content, messages, tool
      # calls, usage, and turn count.
      #
      # @return [RubyPi::Agent::Result] the outcome of the agent run
      def run
        loop do
          # Check iteration limit before starting a new turn
          if @state.max_iterations_reached?
            return build_result(content: last_assistant_content)
          end

          # Apply context compaction if configured and needed
          compact_if_needed!

          # THINK: Call the LLM
          response = think

          # Track usage from this turn
          accumulate_usage(response.usage)

          # Increment iteration counter
          @state.increment_iteration!

          if response.tool_calls?
            # ACT: Execute tool calls
            act(response)

            # OBSERVE: Tool results have been added to messages; loop continues
            @emitter.emit(:turn_end, turn: @state.iteration, has_tool_calls: true)
          else
            # No tool calls — the LLM is done
            @emitter.emit(:turn_end, turn: @state.iteration, has_tool_calls: false)
            return build_result(content: response.content)
          end
        end
      rescue StandardError => e
        @emitter.emit(:error, error: e, source: :agent_loop)
        Result.new(
          content: nil,
          messages: @state.messages,
          tool_calls_made: @tool_calls_made,
          usage: @total_usage,
          turns: @state.iteration,
          error: e
        )
      end

      private

      # THINK phase: applies transforms, calls the LLM, and streams text
      # deltas back through the emitter.
      #
      # @return [RubyPi::LLM::Response] the LLM response
      def think
        # Apply transform_context hook before the LLM call
        @state.transform_context&.call(@state)

        @emitter.emit(:turn_start, turn: @state.iteration + 1)

        # Build the messages array for the LLM call, prepending the system prompt
        messages = build_llm_messages

        # Build tools array for the LLM
        tools = build_tools_array

        # Accumulate streamed content
        streamed_content = +""

        # Call the LLM with streaming
        response = @state.model.complete(
          messages: messages,
          tools: tools,
          stream: true
        ) do |event|
          if event.text_delta?
            streamed_content << event.data.to_s
            @emitter.emit(:text_delta, content: event.data)
          end
        end

        # Add the assistant's response to conversation history
        assistant_message = { role: :assistant, content: response.content }
        if response.tool_calls?
          assistant_message[:tool_calls] = response.tool_calls.map(&:to_h)
        end
        @state.add_message(**assistant_message)

        response
      end

      # ACT phase: executes each tool call from the LLM response, firing
      # lifecycle hooks and events around each execution.
      #
      # @param response [RubyPi::LLM::Response] the LLM response with tool calls
      # @return [void]
      def act(response)
        executor = RubyPi::Tools::Executor.new(
          @state.tools,
          mode: :parallel,
          timeout: 30
        )

        # Prepare call hashes for the executor
        calls = response.tool_calls.map do |tc|
          { name: tc.name, arguments: tc.arguments }
        end

        # Fire before_tool_call hooks and emit start events
        response.tool_calls.each do |tc|
          @state.before_tool_call&.call(tc)
          @emitter.emit(:tool_execution_start, tool_name: tc.name, arguments: tc.arguments)
        end

        # Execute all tool calls
        results = executor.execute(calls)

        # Fire after_tool_call hooks, emit end events, and add results to messages
        response.tool_calls.each_with_index do |tc, idx|
          result = results[idx]

          @state.after_tool_call&.call(tc, result)
          @emitter.emit(:tool_execution_end,
                        tool_name: tc.name,
                        result: result,
                        success: result.success?,
                        duration_ms: result.duration_ms)

          # Record the tool call for the final result
          @tool_calls_made << {
            tool_name: tc.name,
            arguments: tc.arguments,
            result: result.to_h
          }

          # Add tool result to conversation as a tool-role message
          result_content = result.success? ? JSON.generate(result.value) : "Error: #{result.error}"
          @state.add_message(
            role: :tool,
            content: result_content,
            tool_call_id: tc.id,
            name: tc.name
          )
        end
      end

      # Builds the messages array for the LLM, prepending the system prompt
      # as the first message.
      #
      # @return [Array<Hash>] messages formatted for the LLM provider
      def build_llm_messages
        system_message = { role: :system, content: @state.system_prompt }
        [system_message] + @state.messages
      end

      # Converts the tool registry into an array of tool definition hashes
      # suitable for the LLM call. Returns an empty array if no tools are
      # registered.
      #
      # @return [Array<Hash>] tool definitions
      def build_tools_array
        return [] unless @state.tools

        @state.tools.all
      end

      # Accumulates token usage from a single LLM response into the running
      # total.
      #
      # @param usage [Hash] usage from one response
      # @return [void]
      def accumulate_usage(usage)
        return unless usage.is_a?(Hash)

        @total_usage[:input_tokens] += (usage[:prompt_tokens] || usage[:input_tokens] || 0)
        @total_usage[:output_tokens] += (usage[:completion_tokens] || usage[:output_tokens] || 0)
      end

      # Triggers context compaction if a compaction strategy is configured
      # and the estimated token count exceeds the threshold.
      #
      # @return [void]
      def compact_if_needed!
        return unless @compaction

        compacted = @compaction.compact(@state.messages, @state.system_prompt)
        return unless compacted # nil means no compaction was needed

        @state.messages = compacted
      end

      # Extracts the last assistant message content from the conversation
      # history. Used as the final content when max iterations are reached.
      #
      # @return [String, nil] the last assistant content or nil
      def last_assistant_content
        @state.messages
              .select { |m| m[:role] == :assistant }
              .last
              &.dig(:content)
      end

      # Constructs the final Agent::Result from the current state.
      #
      # @param content [String, nil] the final text content
      # @return [RubyPi::Agent::Result]
      def build_result(content:)
        Result.new(
          content: content,
          messages: @state.messages,
          tool_calls_made: @tool_calls_made,
          usage: @total_usage,
          turns: @state.iteration
        )
      end
    end
  end
end
