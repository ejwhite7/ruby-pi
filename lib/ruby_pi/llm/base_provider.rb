# frozen_string_literal: true

# lib/ruby_pi/llm/base_provider.rb
#
# Abstract base class for all LLM providers. Implements shared concerns such as
# retry logic with exponential backoff and a consistent public interface. Concrete
# providers (Gemini, Anthropic, OpenAI) must subclass this and implement the
# abstract methods.

module RubyPi
  module LLM
    # Abstract base class that defines the contract every LLM provider must
    # fulfill. Provides built-in retry logic with exponential backoff for
    # transient errors and a unified #complete interface for both synchronous
    # and streaming completions.
    #
    # Subclasses MUST implement:
    # - #perform_complete(messages:, tools:, stream:, &block)
    # - #model_name
    # - #provider_name
    #
    # @example Subclass implementation
    #   class MyProvider < RubyPi::LLM::BaseProvider
    #     def model_name = "my-model"
    #     def provider_name = :my_provider
    #
    #     private
    #     def perform_complete(messages:, tools:, stream:, &block)
    #       # Make HTTP request and return RubyPi::LLM::Response
    #     end
    #   end
    class BaseProvider
      # @return [Integer] maximum number of retry attempts
      attr_reader :max_retries

      # @return [Float] base delay in seconds for exponential backoff
      attr_reader :retry_base_delay

      # @return [Float] maximum delay in seconds between retries
      attr_reader :retry_max_delay

      # Initializes the base provider with retry configuration.
      #
      # @param max_retries [Integer, nil] override max retries (defaults to global config)
      # @param retry_base_delay [Float, nil] override base delay (defaults to global config)
      # @param retry_max_delay [Float, nil] override max delay (defaults to global config)
      def initialize(max_retries: nil, retry_base_delay: nil, retry_max_delay: nil)
        config = RubyPi.configuration
        @max_retries = max_retries || config.max_retries
        @retry_base_delay = retry_base_delay || config.retry_base_delay
        @retry_max_delay = retry_max_delay || config.retry_max_delay
      end

      # Sends a completion request to the LLM provider with automatic retry
      # logic for transient errors. When stream is true and a block is given,
      # yields StreamEvent objects incrementally as they arrive.
      #
      # @param messages [Array<Hash>] conversation messages, each with :role and :content
      # @param tools [Array<Hash>] tool/function definitions for the model
      # @param stream [Boolean] whether to enable streaming mode
      # @yield [event] yields StreamEvent objects when streaming
      # @yieldparam event [RubyPi::LLM::StreamEvent] a stream event
      # @return [RubyPi::LLM::Response] the normalized response
      # @raise [RubyPi::AuthenticationError] on 401/403 responses
      # @raise [RubyPi::RateLimitError] on 429 responses (after retries exhausted)
      # @raise [RubyPi::ApiError] on other HTTP errors (after retries exhausted)
      # @raise [RubyPi::TimeoutError] on request timeouts
      def complete(messages:, tools: [], stream: false, &block)
        attempt = 0

        begin
          attempt += 1
          perform_complete(messages: messages, tools: tools, stream: stream, &block)
        rescue RubyPi::AuthenticationError
          # Authentication errors are not retryable — raise immediately
          raise
        rescue RubyPi::RateLimitError, RubyPi::ApiError, RubyPi::TimeoutError => e
          # Retry up to max_retries times AFTER the initial attempt.
          # With max_retries: 3, attempt goes 1 (initial), 2, 3, 4 — the condition
          # `attempt <= @max_retries` allows retries on attempts 1..3, so we get
          # 3 retries + 1 initial = 4 total attempts. Previously used `< @max_retries`
          # which was off-by-one (only 2 retries with max_retries: 3).
          if attempt <= @max_retries
            delay = calculate_backoff(attempt)
            log_retry(attempt, delay, e)
            sleep(delay)
            retry
          else
            raise
          end
        end
      end

      # Returns the model name used by this provider instance.
      # Subclasses MUST override this method.
      #
      # @return [String] the model identifier
      # @raise [RubyPi::AbstractMethodError] if not overridden
      def model_name
        raise RubyPi::AbstractMethodError, :model_name
      end

      # Returns the provider identifier.
      # Subclasses MUST override this method.
      #
      # @return [Symbol] the provider identifier (e.g., :gemini, :anthropic, :openai)
      # @raise [RubyPi::AbstractMethodError] if not overridden
      def provider_name
        raise RubyPi::AbstractMethodError, :provider_name
      end

      private

      # Performs the actual completion request. Subclasses MUST implement this
      # method with provider-specific HTTP logic.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions
      # @param stream [Boolean] streaming mode flag
      # @yield [event] optional block for streaming events
      # @return [RubyPi::LLM::Response]
      def perform_complete(messages:, tools:, stream:, &block)
        raise RubyPi::AbstractMethodError, :perform_complete
      end

      # Calculates the backoff delay for a given retry attempt using
      # exponential backoff with jitter.
      #
      # @param attempt [Integer] the current attempt number (1-based)
      # @return [Float] delay in seconds
      def calculate_backoff(attempt)
        base = @retry_base_delay * (2**(attempt - 1))
        jitter = rand * @retry_base_delay * 0.5
        [base + jitter, @retry_max_delay].min
      end

      # Logs a retry attempt if a logger is configured.
      #
      # @param attempt [Integer] current attempt number
      # @param delay [Float] delay before next retry
      # @param error [Exception] the error that triggered the retry
      # @return [void]
      def log_retry(attempt, delay, error)
        logger = RubyPi.configuration.logger
        return unless logger

        logger.warn(
          "[RubyPi::#{provider_name}] Retry #{attempt}/#{@max_retries} " \
          "after #{delay.round(2)}s — #{error.class}: #{error.message}"
        )
      end

      # Builds a Faraday connection with standard settings.
      #
      # Issue #20: Removed incorrect retry-middleware claim from the
      # docstring. The faraday-retry gem was listed as a dependency but never
      # wired into the connection builder. Since retry logic is already
      # implemented in BaseProvider#complete with exponential backoff (see
      # the begin/rescue/retry block), the Faraday-level retry middleware is
      # not needed and would cause confusing double-retry behavior. The
      # faraday-retry dependency has been removed from the gemspec.
      #
      # @param base_url [String] the base URL for the API
      # @param headers [Hash] default headers for all requests
      # @return [Faraday::Connection]
      def build_connection(base_url:, headers: {})
        config = RubyPi.configuration

        Faraday.new(url: base_url) do |conn|
          conn.headers.update(headers)
          conn.options.timeout = config.request_timeout
          conn.options.open_timeout = config.open_timeout
          conn.adapter :net_http
        end
      end

      # Handles HTTP error responses by raising the appropriate RubyPi error.
      #
      # @param response [Faraday::Response] the HTTP response
      # @raise [RubyPi::AuthenticationError] on 401 or 403
      # @raise [RubyPi::RateLimitError] on 429
      # @raise [RubyPi::ApiError] on other error status codes
      def handle_error_response(response)
        case response.status
        when 401, 403
          raise RubyPi::AuthenticationError.new(
            "#{provider_name} authentication failed (HTTP #{response.status})",
            response_body: response.body
          )
        when 429
          retry_after = response.headers["retry-after"]&.to_f
          raise RubyPi::RateLimitError.new(
            "#{provider_name} rate limit exceeded (HTTP 429)",
            retry_after: retry_after,
            response_body: response.body
          )
        else
          raise RubyPi::ApiError.new(
            "#{provider_name} API error (HTTP #{response.status})",
            status_code: response.status,
            response_body: response.body
          )
        end
      end

      # Processes a streaming response body line by line, parsing SSE events.
      # Yields parsed data hashes to the provided block.
      #
      # @param response_body [String] the raw SSE response body
      # @yield [data] parsed SSE event data
      # @yieldparam data [Hash] a parsed JSON event payload
      # @return [void]
      def parse_sse_events(response_body, &block)
        response_body.each_line do |line|
          line = line.strip
          next if line.empty?
          next unless line.start_with?("data: ")

          data_str = line.sub(/\Adata: /, "")
          next if data_str == "[DONE]"

          begin
            data = JSON.parse(data_str)
            block.call(data)
          rescue JSON::ParserError
            # Skip malformed SSE data lines
            next
          end
        end
      end
    end
  end
end
