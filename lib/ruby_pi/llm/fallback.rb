# frozen_string_literal: true

# lib/ruby_pi/llm/fallback.rb
#
# Provides automatic failover between LLM providers. Wraps a primary provider
# with one or more fallback providers. If the primary fails with a retryable
# error, the Fallback wrapper automatically routes the request to the next
# available provider.

module RubyPi
  module LLM
    # A resilient provider wrapper that tries a primary provider first and
    # automatically falls back to an alternative provider on failure. Both
    # providers must conform to the BaseProvider interface.
    #
    # Authentication errors are NOT retried with the fallback since they
    # indicate a configuration problem rather than a transient failure.
    #
    # Issue #23: When streaming, the Fallback now buffers deltas from the
    # primary provider. If the primary fails mid-stream, the buffered deltas
    # are discarded and the fallback provider streams fresh from the start.
    # This prevents the consumer from seeing partial output from the primary
    # concatenated with the complete output from the fallback.
    #
    # @example Setting up a fallback chain
    #   primary  = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
    #   backup   = RubyPi::LLM.model(:openai, "gpt-4o")
    #   provider = RubyPi::LLM::Fallback.new(primary: primary, fallback: backup)
    #
    #   # If Gemini fails, automatically retries with OpenAI
    #   response = provider.complete(messages: messages)
    class Fallback < BaseProvider
      # @return [RubyPi::LLM::BaseProvider] the primary provider
      attr_reader :primary

      # @return [RubyPi::LLM::BaseProvider] the fallback provider
      attr_reader :fallback

      # Creates a new Fallback wrapper with a primary and fallback provider.
      #
      # @param primary [RubyPi::LLM::BaseProvider] the preferred provider
      # @param fallback [RubyPi::LLM::BaseProvider] the backup provider
      # @param options [Hash] additional options passed to BaseProvider
      def initialize(primary:, fallback:, **options)
        super(**options)
        @primary = primary
        @fallback = fallback
      end

      # Returns the model name of the primary provider.
      #
      # @return [String]
      def model_name
        @primary.model_name
      end

      # Returns :fallback as the provider identifier.
      #
      # @return [Symbol]
      def provider_name
        :fallback
      end

      private

      # Attempts the completion with the primary provider. If it fails with
      # a retryable error (ApiError, RateLimitError, TimeoutError, ProviderError),
      # the request is retried with the fallback provider. Authentication errors
      # propagate immediately since they indicate misconfiguration.
      #
      # Issue #23: When streaming with a block, we buffer deltas from the
      # primary provider and only flush them to the real block once the
      # primary completes successfully. If the primary fails mid-stream,
      # the buffer is discarded and the fallback streams directly to the
      # consumer's block, preventing double-emission of partial content.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] streaming mode flag
      # @yield [event] optional block for streaming events
      # @return [RubyPi::LLM::Response]
      def perform_complete(messages:, tools:, stream:, &block)
        if stream && block_given?
          perform_complete_with_streaming_fallback(messages: messages, tools: tools, &block)
        else
          perform_complete_without_streaming(messages: messages, tools: tools, stream: stream, &block)
        end
      end

      # Non-streaming fallback — simple try primary, rescue, try fallback.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] streaming mode flag
      # @yield [event] optional block for streaming events
      # @return [RubyPi::LLM::Response]
      def perform_complete_without_streaming(messages:, tools:, stream:, &block)
        @primary.complete(messages: messages, tools: tools, stream: stream, &block)
      rescue RubyPi::AuthenticationError
        # Configuration errors should not trigger fallback
        raise
      rescue RubyPi::Error => e
        log_fallback(e)
        @fallback.complete(messages: messages, tools: tools, stream: stream, &block)
      end

      # Streaming fallback with delta buffering.
      #
      # Issue #23: Buffers all streaming events from the primary provider.
      # If the primary completes successfully, flushes the buffered events
      # to the consumer's block. If it fails, discards the buffer and
      # streams directly from the fallback provider.
      #
      # This prevents the consumer from seeing:
      #   primary partial tokens + fallback complete tokens
      # which would produce garbled, concatenated output.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @yield [event] the consumer's streaming block
      # @return [RubyPi::LLM::Response]
      def perform_complete_with_streaming_fallback(messages:, tools:, &block)
        # Buffer events from the primary provider
        buffered_events = []

        begin
          response = @primary.complete(
            messages: messages,
            tools: tools,
            stream: true
          ) do |event|
            # Buffer events instead of yielding directly to the consumer.
            # We'll flush them after the primary completes successfully.
            buffered_events << event
          end

          # Primary succeeded — flush buffered events to the consumer
          buffered_events.each { |event| block.call(event) }

          response
        rescue RubyPi::AuthenticationError
          # Configuration errors should not trigger fallback
          raise
        rescue RubyPi::Error => e
          log_fallback(e)

          # Discard buffered events from the failed primary.
          # Stream directly from the fallback to the consumer's block.
          buffered_events.clear

          @fallback.complete(
            messages: messages,
            tools: tools,
            stream: true,
            &block
          )
        end
      end

      # Logs the fallback event if a logger is configured.
      #
      # @param error [Exception] the error that triggered the fallback
      # @return [void]
      def log_fallback(error)
        logger = RubyPi.configuration.logger
        return unless logger

        logger.warn(
          "[RubyPi::Fallback] Primary provider (#{@primary.provider_name}/#{@primary.model_name}) " \
          "failed with #{error.class}: #{error.message}. " \
          "Falling back to #{@fallback.provider_name}/#{@fallback.model_name}."
        )
      end
    end
  end
end
