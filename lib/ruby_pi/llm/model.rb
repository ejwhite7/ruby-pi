# frozen_string_literal: true

# lib/ruby_pi/llm/model.rb
#
# Represents a model identifier combining a provider and model name. Used as
# a lightweight descriptor that can be passed around and later instantiated
# into a full provider instance via the factory method.

module RubyPi
  module LLM
    # A model descriptor that pairs a provider identifier with a specific
    # model name. Use the factory method RubyPi::LLM.model to create provider
    # instances directly, or instantiate a Model object for deferred construction.
    #
    # @example Creating a model descriptor
    #   model = RubyPi::LLM::Model.new(provider: :gemini, name: "gemini-2.0-flash")
    #   model.provider  # => :gemini
    #   model.name       # => "gemini-2.0-flash"
    #   provider = model.build  # => RubyPi::LLM::Gemini instance
    #
    # @example Using the factory shortcut
    #   provider = RubyPi::LLM.model(:openai, "gpt-4o")
    class Model
      # @return [Symbol] the provider identifier (:gemini, :anthropic, :openai)
      attr_reader :provider

      # @return [String] the model name within the provider
      attr_reader :name

      # Creates a new Model descriptor.
      #
      # @param provider [Symbol, String] provider identifier
      # @param name [String] model name
      def initialize(provider:, name:)
        @provider = provider.to_sym
        @name = name.to_s
      end

      # Builds a configured provider instance from this model descriptor.
      # Delegates to RubyPi::LLM.model for provider construction.
      #
      # @param options [Hash] additional options passed to the provider constructor
      # @return [RubyPi::LLM::BaseProvider] a configured provider instance
      def build(**options)
        RubyPi::LLM.model(@provider, @name, **options)
      end

      # Returns a hash representation of the model descriptor.
      #
      # @return [Hash]
      def to_h
        { provider: @provider, name: @name }
      end

      # Returns a human-readable string representation.
      #
      # @return [String]
      def to_s
        "#<RubyPi::LLM::Model provider=#{@provider.inspect} name=#{@name.inspect}>"
      end

      alias_method :inspect, :to_s

      # Equality comparison based on provider and name.
      #
      # @param other [RubyPi::LLM::Model] another model descriptor
      # @return [Boolean]
      def ==(other)
        other.is_a?(Model) && @provider == other.provider && @name == other.name
      end

      alias_method :eql?, :==

      # Hash code for use in hash keys and sets.
      #
      # @return [Integer]
      def hash
        [@provider, @name].hash
      end
    end
  end
end
