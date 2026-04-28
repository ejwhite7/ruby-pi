# frozen_string_literal: true

# lib/ruby_pi/errors.rb
#
# Defines the error hierarchy for the RubyPi framework. All RubyPi exceptions
# inherit from RubyPi::Error, which itself inherits from StandardError.
# This allows callers to rescue specific error types or catch all RubyPi
# errors with a single rescue clause.

module RubyPi
  # Base error class for all RubyPi exceptions. Rescue this to catch any
  # error originating from the RubyPi framework.
  #
  # @example Catching all RubyPi errors
  #   begin
  #     provider.complete(messages: msgs)
  #   rescue RubyPi::Error => e
  #     logger.error("RubyPi error: #{e.message}")
  #   end
  class Error < StandardError; end

  # Raised when an API request fails due to a server-side or client-side
  # HTTP error (e.g., 400, 500). Includes the HTTP status code and the
  # response body for debugging.
  class ApiError < Error
    # @return [Integer, nil] the HTTP status code returned by the API
    attr_reader :status_code

    # @return [String, nil] the raw response body from the API
    attr_reader :response_body

    # @param message [String] human-readable error description
    # @param status_code [Integer, nil] HTTP status code
    # @param response_body [String, nil] raw response body
    def initialize(message = nil, status_code: nil, response_body: nil)
      @status_code = status_code
      @response_body = response_body
      super(message || "API request failed with status #{status_code}")
    end
  end

  # Raised when authentication fails (HTTP 401 or 403). Typically indicates
  # an invalid, expired, or missing API key.
  class AuthenticationError < ApiError
    # @param message [String] human-readable error description
    # @param response_body [String, nil] raw response body
    def initialize(message = nil, response_body: nil)
      super(message || "Authentication failed — check your API key", status_code: 401, response_body: response_body)
    end
  end

  # Raised when the API returns a rate limit response (HTTP 429). The caller
  # should back off and retry after the indicated period.
  class RateLimitError < ApiError
    # @return [Float, nil] suggested retry delay in seconds, if provided by the API
    attr_reader :retry_after

    # @param message [String] human-readable error description
    # @param retry_after [Float, nil] seconds to wait before retrying
    # @param response_body [String, nil] raw response body
    def initialize(message = nil, retry_after: nil, response_body: nil)
      @retry_after = retry_after
      super(message || "Rate limit exceeded", status_code: 429, response_body: response_body)
    end
  end

  # Raised when an HTTP request times out before receiving a response.
  class TimeoutError < Error
    # @param message [String] human-readable error description
    def initialize(message = nil)
      super(message || "Request timed out")
    end
  end

  # Raised when a provider-specific error occurs that does not map to one
  # of the more specific error types. Includes the provider name for context.
  class ProviderError < Error
    # @return [Symbol, String] the name of the provider that raised the error
    attr_reader :provider

    # @param message [String] human-readable error description
    # @param provider [Symbol, String] provider identifier (e.g., :gemini, :anthropic)
    def initialize(message = nil, provider: nil)
      @provider = provider
      super(message || "Provider error from #{provider}")
    end
  end

  # Raised when a subclass does not implement a required abstract method
  # from a base class.
  class NotImplementedError < Error
    # @param method_name [String, Symbol] the name of the unimplemented method
    def initialize(method_name = nil)
      super(method_name ? "Subclass must implement ##{method_name}" : "Subclass must implement this method")
    end
  end
end
