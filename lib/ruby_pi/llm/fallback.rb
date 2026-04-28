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
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] streaming mode flag
      # @yield [event] optional block for streaming events
      # @return [RubyPi::LLM::Response]
      def perform_complete(messages:, tools:, stream:, &block)
        @primary.complete(messages: messages, tools: tools, stream: stream, &block)
      rescue RubyPi::AuthenticationError
        # Configuration errors should not trigger fallback
        raise
      rescue RubyPi::Error => e
        log_fallback(e)
        @fallback.complete(messages: messages, tools: tools, stream: stream, &block)
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
