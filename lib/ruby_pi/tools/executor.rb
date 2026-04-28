# frozen_string_literal: true

# lib/ruby_pi/tools/executor.rb
#
# RubyPi::Tools::Executor — Executes tool calls in parallel or sequentially.
#
# The Executor takes a Registry of tools and a list of tool call requests,
# dispatching each call to the appropriate tool. In `:parallel` mode it uses
# `concurrent-ruby`'s thread pool (Concurrent::Future) to run tools concurrently.
# In `:sequential` mode, tools are executed one after another.
#
# Each execution is wrapped in error handling: if a tool raises an exception,
# the error is captured in a Result with `success: false`. A configurable
# per-tool timeout (default 30 seconds) prevents runaway executions.
#
# Usage:
#   executor = RubyPi::Tools::Executor.new(registry, mode: :parallel, timeout: 30)
#   results = executor.execute([
#     { name: "create_post", arguments: { content: "Hello" } },
#     { name: "get_analytics", arguments: { period: "7d" } }
#   ])
#   # => Array of RubyPi::Tools::Result

require "concurrent"

module RubyPi
  module Tools
    class Executor
      # Default timeout for each tool execution, in seconds.
      DEFAULT_TIMEOUT = 30

      # @return [Symbol] The execution mode (:parallel or :sequential).
      attr_reader :mode

      # @return [Numeric] The per-tool timeout in seconds.
      attr_reader :timeout

      # Creates a new Executor.
      #
      # @param registry [RubyPi::Tools::Registry] The registry to look up tools from.
      # @param mode [Symbol] Execution mode — :parallel or :sequential.
      # @param timeout [Numeric] Per-tool timeout in seconds (default: 30).
      # @raise [ArgumentError] If mode is not :parallel or :sequential.
      def initialize(registry, mode: :parallel, timeout: DEFAULT_TIMEOUT)
        unless %i[parallel sequential].include?(mode)
          raise ArgumentError, "Mode must be :parallel or :sequential, got #{mode.inspect}"
        end

        @registry = registry
        @mode = mode
        @timeout = timeout
      end

      # Executes a list of tool calls and returns their results.
      #
      # Each call is a hash with `:name` (String or Symbol) and `:arguments` (Hash).
      # Tools are looked up in the registry; if a tool is not found, a failure
      # Result is returned for that call.
      #
      # @param calls [Array<Hash>] Tool call requests, each with :name and :arguments.
      # @return [Array<RubyPi::Tools::Result>] Results in the same order as the calls.
      def execute(calls)
        case @mode
        when :parallel
          execute_parallel(calls)
        when :sequential
          execute_sequential(calls)
        end
      end

      private

      # Executes tool calls sequentially, one after another.
      #
      # @param calls [Array<Hash>] The tool call requests.
      # @return [Array<RubyPi::Tools::Result>] Ordered results.
      def execute_sequential(calls)
        calls.map { |call| execute_single(call) }
      end

      # Executes tool calls in parallel using concurrent-ruby Futures.
      #
      # Each call is dispatched as a Future on the global I/O thread pool.
      # Results are collected in order, respecting the per-tool timeout.
      #
      # @param calls [Array<Hash>] The tool call requests.
      # @return [Array<RubyPi::Tools::Result>] Ordered results.
      def execute_parallel(calls)
        futures = calls.map do |call|
          Concurrent::Future.execute(executor: :io) do
            execute_single(call)
          end
        end

        # Collect results, respecting the configured timeout for each future.
        futures.map do |future|
          future.value(@timeout) || Result.new(
            name: "unknown",
            success: false,
            error: "Tool execution timed out after #{@timeout}s",
            duration_ms: @timeout * 1000.0
          )
        end
      end

      # Executes a single tool call with error handling and timing.
      #
      # @param call [Hash] A tool call with :name and :arguments keys.
      # @return [RubyPi::Tools::Result] The execution result.
      def execute_single(call)
        tool_name = (call[:name] || call["name"]).to_s
        arguments = call[:arguments] || call["arguments"] || {}

        tool = @registry.find(tool_name)

        # Return an error result if the tool is not registered
        unless tool
          return Result.new(
            name: tool_name,
            success: false,
            error: "Tool '#{tool_name}' not found in registry",
            duration_ms: 0.0
          )
        end

        # Execute the tool with timeout and error handling
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          value = Timeout.timeout(@timeout) do
            tool.call(arguments)
          end
          elapsed_ms = elapsed_since(start_time)

          Result.new(
            name: tool_name,
            success: true,
            value: value,
            duration_ms: elapsed_ms
          )
        rescue Timeout::Error
          elapsed_ms = elapsed_since(start_time)
          Result.new(
            name: tool_name,
            success: false,
            error: "Tool '#{tool_name}' timed out after #{@timeout}s",
            duration_ms: elapsed_ms
          )
        rescue StandardError => e
          elapsed_ms = elapsed_since(start_time)
          Result.new(
            name: tool_name,
            success: false,
            error: "#{e.class}: #{e.message}",
            duration_ms: elapsed_ms
          )
        end
      end

      # Calculates milliseconds elapsed since a monotonic clock timestamp.
      #
      # @param start_time [Float] The start timestamp from Process.clock_gettime.
      # @return [Float] Elapsed time in milliseconds.
      def elapsed_since(start_time)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0
      end
    end
  end
end
