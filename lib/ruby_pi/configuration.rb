# frozen_string_literal: true

# lib/ruby_pi/configuration.rb
#
# Global configuration for the RubyPi framework. Provides a centralized place
# to set API keys, retry behavior, timeouts, and default model preferences.
# Configure via RubyPi.configure { |c| c.gemini_api_key = "..." }.
#
# Supports both global (singleton) and per-agent configuration. Pass a
# Configuration instance to Agent::Core via the `config:` kwarg to override
# the global defaults for that agent.

module RubyPi
  # Holds all configurable settings for the RubyPi framework.
  #
  # @example Setting API keys and retry behavior
  #   RubyPi.configure do |config|
  #     config.gemini_api_key   = ENV["GEMINI_API_KEY"]
  #     config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  #     config.openai_api_key   = ENV["OPENAI_API_KEY"]
  #     config.max_retries      = 5
  #     config.retry_base_delay = 2.0
  #   end
  #
  # @example Per-agent configuration override
  #   custom_config = RubyPi::Configuration.new
  #   custom_config.openai_api_key = "per-agent-key"
  #   agent = RubyPi::Agent.new(system_prompt: "...", model: model, config: custom_config)
  class Configuration
    # @return [String, nil] API key for Google Gemini
    attr_accessor :gemini_api_key

    # @return [String, nil] API key for Anthropic Claude
    attr_accessor :anthropic_api_key

    # @return [String, nil] API key for OpenAI
    attr_accessor :openai_api_key

    # @return [Integer] Maximum number of retry attempts for transient errors (default: 3)
    attr_accessor :max_retries

    # @return [Float] Base delay in seconds for exponential backoff (default: 1.0)
    attr_accessor :retry_base_delay

    # @return [Float] Maximum delay in seconds between retries (default: 30.0)
    attr_accessor :retry_max_delay

    # @return [Integer] HTTP request timeout in seconds (default: 120)
    attr_accessor :request_timeout

    # @return [Integer] HTTP connection open timeout in seconds (default: 10)
    attr_accessor :open_timeout

    # @return [String] Default model name for Gemini provider
    attr_accessor :default_gemini_model

    # @return [String] Default model name for Anthropic provider
    attr_accessor :default_anthropic_model

    # @return [String] Default model name for OpenAI provider
    attr_accessor :default_openai_model

    # @return [Logger, nil] Logger instance for debug output
    attr_accessor :logger

    # Initializes a new Configuration with sensible defaults.
    def initialize
      set_defaults
    end

    # Resets all configuration options to their default values.
    # Uses the shared set_defaults method to avoid calling initialize directly.
    #
    # @return [void]
    def reset!
      set_defaults
    end

    private

    # Sets all configuration ivars to their default values. Called by both
    # initialize and reset! to ensure consistent defaults without the
    # anti-pattern of calling initialize from reset!.
    #
    # @return [void]
    def set_defaults
      @gemini_api_key        = nil
      @anthropic_api_key     = nil
      @openai_api_key        = nil
      @max_retries           = 3
      @retry_base_delay      = 1.0
      @retry_max_delay       = 30.0
      @request_timeout       = 120
      @open_timeout          = 10
      @default_gemini_model  = "gemini-2.0-flash"
      @default_anthropic_model = "claude-sonnet-4-20250514"
      @default_openai_model  = "gpt-4o"
      @logger                = nil
    end
  end
end
