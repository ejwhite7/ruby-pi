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
      # Issue #17: Raises NoToolsRegisteredError if the registry is nil and
      # tool calls are attempted, preventing a confusing NoMethodError.
      #
      # @param calls [Array<Hash>] Tool call requests, each with :name and :arguments.
      # @return [Array<RubyPi::Tools::Result>] Results in the same order as the calls.
      # @raise [RubyPi::NoToolsRegisteredError] if registry is nil
      def execute(calls)
        # Issue #17: Guard against nil registry — if the LLM hallucinated tool
        # calls but no tools are registered, raise a typed error immediately
        # rather than crashing with NoMethodError on nil.find.
        if @registry.nil?
          raise RubyPi::NoToolsRegisteredError,
                "Model returned #{calls.size} tool call(s) but no tools are registered"
        end

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
      # Issue #10: Uses future.wait(@timeout) + future.complete? to distinguish
      # a legitimate nil return value from a timeout. Previously, the || operator
      # treated nil return values as timeouts.
      #
      # Issue #11: After detecting a timeout, attempts to cancel the future.
      # Note: Ruby threads cannot be forcibly killed safely; we use the future's
      # cancellation mechanism which sets a flag. The underlying thread may
      # continue running until it reaches a natural exit point. This is a known
      # tradeoff — hard cancellation in Ruby risks corrupted state.
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
          # Issue #10: Wait for the future to complete, then check its state
          # explicitly. Future#value returns nil both on timeout AND when the
          # block legitimately returned nil, so we cannot use || to distinguish.
          future.wait(@timeout)

          if future.complete?
            if future.fulfilled?
              # Future completed successfully — return its value (which may be nil)
              future.value
            else
              # Future was rejected (raised an exception within the block).
              # This shouldn't normally happen since execute_single rescues
              # internally, but handle it defensively.
              error = future.reason
              Result.new(
                name: "unknown",
                success: false,
                error: "#{error.class}: #{error.message}",
                duration_ms: @timeout * 1000.0
              )
            end
          else
            # Issue #11: Future did not complete within the timeout window.
            # Attempt to cancel the future to signal the thread to stop.
            # Concurrent::Future does not support hard cancellation — the
            # underlying thread will continue until it naturally exits.
            # This is the safest approach in Ruby since Thread#raise/Thread#kill
            # can interrupt mid-mutation and corrupt shared state.
            future.cancel if future.respond_to?(:cancel)

            Result.new(
              name: "unknown",
              success: false,
              error: "Tool execution timed out after #{@timeout}s",
              duration_ms: @timeout * 1000.0
            )
          end
        end
      end

      # Executes a single tool call with error handling and timing.
      #
      # Issue #9: Replaced the stdlib timeout mechanism with a thread+join approach for
      # sequential mode. The stdlib timeout uses Thread#raise internally, which
      # is unsafe — it can interrupt code mid-mutation, leak file handles,
      # and corrupt state. The thread+join approach runs the tool in a
      # separate thread and waits with a timeout; if the thread doesn't
      # finish in time, we report a timeout error. The worker thread is
      # left running (it cannot be safely killed in Ruby) but its result
      # is discarded.
      #
      # @param call [Hash] A tool call with :name and :arguments keys.
      # @return [RubyPi::Tools::Result] The execution result.
      def execute_single(call)
        tool_name = (call[:name] || call["name"]).to_s
        arguments = deep_symbolize_keys(call[:arguments] || call["arguments"] || {})

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

        # Execute the tool with a safe timeout mechanism.
        # Instead of the stdlib timeout (which uses Thread#raise and is unsafe),
        # we spawn a worker thread and join with a timeout.
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Container for the worker thread's result/error
        value = nil
        error = nil

        worker = Thread.new do
          # Don't spam stderr from the rescued worker thread.
          Thread.current.report_on_exception = false
          begin
            value = tool.call(arguments)
          rescue Exception => e # rubocop:disable Lint/RescueException
            # Rescue the full Exception hierarchy (not just StandardError).
            # If a tool block raises Interrupt, SystemExit, or any other
            # non-StandardError, rescuing only StandardError leaves both
            # `value` and `error` nil; the join then reports a successful
            # nil result — a panic in a tool silently becomes "returned nil".
            # Capture the failure here; the main thread surfaces it as a
            # failed Result. The worker thread itself does not propagate.
            error = e
          end
        end

        # Join with timeout — returns nil if the thread didn't finish in time
        finished = worker.join(@timeout)

        elapsed_ms = elapsed_since(start_time)

        if finished.nil?
          # Thread did not finish within the timeout. We cannot safely kill it
          # (Thread#kill can corrupt state), so we leave it running and report
          # the timeout. This matches the tradeoff documented for parallel mode.
          Result.new(
            name: tool_name,
            success: false,
            error: "Tool '#{tool_name}' timed out after #{@timeout}s",
            duration_ms: elapsed_ms
          )
        elsif error
          Result.new(
            name: tool_name,
            success: false,
            error: "#{error.class}: #{error.message}",
            duration_ms: elapsed_ms
          )
        else
          Result.new(
            name: tool_name,
            success: true,
            value: value,
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

      # Recursively converts all string keys in a hash to symbols so that
      # tool implementations can use idiomatic Ruby symbol-key access
      # (e.g. `args[:field]`) regardless of whether the LLM provider
      # returned string-keyed JSON. Exposed as a class method so the agent
      # loop can apply the same transformation to tool_call arguments
      # before recording them in `tool_calls_made`, keeping the agent's
      # observable arguments shape consistent with what tool blocks see.
      #
      # @param obj [Object] the object to transform (Hash, Array, or scalar)
      # @return [Object] the transformed object with symbolized keys
      def self.deep_symbolize_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(key, value), result|
            result[key.to_sym] = deep_symbolize_keys(value)
          end
        when Array
          obj.map { |item| deep_symbolize_keys(item) }
        else
          obj
        end
      end

      # Instance-method delegate so existing internal callers keep working.
      #
      # @param obj [Object] the object to transform (Hash, Array, or scalar)
      # @return [Object] the transformed object with symbolized keys
      def deep_symbolize_keys(obj)
        self.class.deep_symbolize_keys(obj)
      end
    end
  end
end
