# frozen_string_literal: true

# lib/ruby_pi/tools/result.rb
#
# RubyPi::Tools::Result — Encapsulates the outcome of a tool execution.
#
# Every tool invocation (whether successful or failed) produces a Result object.
# This provides a uniform interface for inspecting execution outcomes, including
# the return value, any error messages, and timing information.
#
# Usage:
#   result = RubyPi::Tools::Result.new(
#     name: "create_post",
#     success: true,
#     value: { post_id: "123" },
#     duration_ms: 42.5
#   )
#
#   result.success?    # => true
#   result.value       # => { post_id: "123" }
#   result.error       # => nil
#   result.duration_ms # => 42.5

module RubyPi
  module Tools
    class Result
      # @return [String] The name of the tool that was executed.
      attr_reader :name

      # @return [Object, nil] The return value of the tool (nil if execution failed).
      attr_reader :value

      # @return [String, nil] The error message if execution failed (nil if successful).
      attr_reader :error

      # @return [Float] The execution time in milliseconds.
      attr_reader :duration_ms

      # Creates a new Result instance.
      #
      # @param name [String, Symbol] The name of the tool that produced this result.
      # @param success [Boolean] Whether the tool executed successfully.
      # @param value [Object, nil] The return value from the tool (on success).
      # @param error [String, nil] The error message (on failure).
      # @param duration_ms [Float] How long the tool took to execute, in milliseconds.
      def initialize(name:, success:, value: nil, error: nil, duration_ms: 0.0)
        @name = name.to_s
        @success = success
        @value = value
        @error = error
        @duration_ms = duration_ms.to_f
      end

      # Returns whether the tool execution was successful.
      #
      # @return [Boolean] true if the tool completed without error.
      def success?
        @success
      end

      # Returns a hash representation of the result, useful for serialization.
      #
      # @return [Hash] A hash containing all result attributes.
      def to_h
        {
          name: @name,
          success: @success,
          value: @value,
          error: @error,
          duration_ms: @duration_ms
        }
      end

      # Provides a human-readable string representation of the result.
      #
      # @return [String] A summary string for debugging/logging.
      def inspect
        status = @success ? "success" : "failure"
        "#<RubyPi::Tools::Result name=#{@name.inspect} status=#{status} duration_ms=#{@duration_ms}>"
      end
    end
  end
end
