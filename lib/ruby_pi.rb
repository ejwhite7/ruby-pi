# frozen_string_literal: true

# lib/ruby_pi.rb
#
# Main entry point for the RubyPi gem. Requiring this file loads the complete
# public API, including configuration, error classes, all LLM provider
# implementations, tool definitions, agent core, context management, and
# extensions. This file also exposes module-level convenience methods for
# configuration and model construction.

require "json"
require "faraday"
# Issue #20: Removed faraday/retry — retry logic is handled by BaseProvider#complete
# require "faraday/retry"
require "faraday/net_http"
require "concurrent-ruby"

require_relative "ruby_pi/version"
require_relative "ruby_pi/configuration"
require_relative "ruby_pi/errors"
require_relative "ruby_pi/llm/response"
require_relative "ruby_pi/llm/tool_call"
require_relative "ruby_pi/llm/stream_event"
require_relative "ruby_pi/llm/model"
require_relative "ruby_pi/llm/base_provider"
require_relative "ruby_pi/llm/gemini"
require_relative "ruby_pi/llm/anthropic"
require_relative "ruby_pi/llm/openai"
require_relative "ruby_pi/llm/fallback"

# Tools
require_relative "ruby_pi/tools/schema"
require_relative "ruby_pi/tools/definition"
require_relative "ruby_pi/tools/registry"
require_relative "ruby_pi/tools/result"
require_relative "ruby_pi/tools/executor"

# Agent
require_relative "ruby_pi/agent/events"
require_relative "ruby_pi/agent/state"
require_relative "ruby_pi/agent/result"
require_relative "ruby_pi/agent/loop"
require_relative "ruby_pi/agent/core"

# Context
require_relative "ruby_pi/context/compaction"
require_relative "ruby_pi/context/transform"

# Extensions
require_relative "ruby_pi/extensions/base"

# Top-level namespace for the RubyPi framework.
module RubyPi
  class << self
    # Returns the global configuration object.
    #
    # @return [RubyPi::Configuration] the current global configuration
    def configuration
      @configuration ||= Configuration.new
    end

    # Yields the global configuration object to a block for mutation.
    #
    # @yield [configuration] the global configuration instance
    # @return [RubyPi::Configuration] the updated configuration
    #
    # @example Configure API keys
    #   RubyPi.configure do |config|
    #     config.openai_api_key = ENV["OPENAI_API_KEY"]
    #     config.max_retries = 5
    #   end
    def configure
      yield(configuration) if block_given?
      configuration
    end

    # Resets the global configuration to default values.
    #
    # @return [void]
    def reset_configuration!
      @configuration = Configuration.new
    end
  end

  # Namespace for large language model providers and related abstractions.
  module LLM
    class << self
      # Factory method for constructing a provider instance from a provider name
      # and model identifier.
      #
      # @param provider [Symbol, String] provider identifier (:gemini, :anthropic, :openai)
      # @param name [String] the model name to use with the provider
      # @param options [Hash] provider-specific initialization options
      # @return [RubyPi::LLM::BaseProvider] configured provider instance
      # @raise [ArgumentError] if the provider is unsupported
      #
      # @example Build a Gemini model
      #   model = RubyPi::LLM.model(:gemini, "gemini-2.0-flash")
      def model(provider, name, **options)
        case provider.to_sym
        when :gemini
          Gemini.new(model: name, **options)
        when :anthropic
          Anthropic.new(model: name, **options)
        when :openai
          OpenAI.new(model: name, **options)
        else
          raise ArgumentError, "Unsupported provider: #{provider}"
        end
      end
    end
  end
end
