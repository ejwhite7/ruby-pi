# frozen_string_literal: true

# lib/ruby_pi/tools/registry.rb
#
# RubyPi::Tools::Registry — A thread-safe store for tool definitions.
#
# The Registry holds a collection of tool definitions and provides methods
# for looking them up by name, filtering by category, and extracting subsets.
# All public methods are protected by a Mutex for thread safety, ensuring
# safe concurrent access from agent loops and parallel tool execution.
#
# Usage:
#   registry = RubyPi::Tools::Registry.new
#   registry.register(my_tool)
#   registry.find(:my_tool)            # => Definition or nil
#   registry.by_category(:content)     # => [Definition, ...]
#   registry.subset([:tool_a, :tool_b])# => Registry (new instance)
#   registry.names                     # => [:tool_a, :tool_b, ...]

module RubyPi
  module Tools
    class Registry
      # Creates a new, empty Registry.
      def initialize
        @tools = {}
        @mutex = Mutex.new
      end

      # Registers a tool definition in the registry.
      #
      # If a tool with the same name already exists, it will be overwritten.
      # A debug-level log message is emitted if a logger is configured;
      # otherwise the overwrite is silent (no warn to stderr).
      #
      # @param tool [RubyPi::Tools::Definition] The tool to register.
      # @return [RubyPi::Tools::Definition] The registered tool.
      # @raise [ArgumentError] If the argument is not a Definition.
      def register(tool)
        unless tool.is_a?(RubyPi::Tools::Definition)
          raise ArgumentError, "Expected a RubyPi::Tools::Definition, got #{tool.class}"
        end

        @mutex.synchronize do
          if @tools.key?(tool.name)
            # Use the configured logger at debug level instead of unconditional
            # warn to stderr, which is noisy in production environments.
            logger = RubyPi.configuration.logger
            if logger
              logger.debug("RubyPi::Tools::Registry: overwriting existing tool '#{tool.name}'")
            end
          end
          @tools[tool.name] = tool
        end

        tool
      end

      # Finds a tool by name. Thread-safe.
      #
      # @param name [String, Symbol] The name of the tool to look up.
      # @return [RubyPi::Tools::Definition, nil] The tool, or nil if not found.
      def find(name)
        @mutex.synchronize { @tools[name.to_sym] }
      end

      # Returns a new Registry containing only the tools with the given names.
      #
      # Tools that are not found in this registry are silently skipped.
      # Thread-safe.
      #
      # @param names [Array<String, Symbol>] The tool names to include.
      # @return [RubyPi::Tools::Registry] A new registry with the matching tools.
      def subset(names)
        sub = Registry.new
        names.each do |name|
          tool = find(name)
          sub.register(tool) if tool
        end
        sub
      end

      # Returns all tools that belong to the given category. Thread-safe.
      #
      # @param category [Symbol, String] The category to filter by.
      # @return [Array<RubyPi::Tools::Definition>] Tools matching the category.
      def by_category(category)
        cat = category.to_sym
        @mutex.synchronize do
          @tools.values.select { |tool| tool.category == cat }
        end
      end

      # Returns all registered tool definitions. Thread-safe.
      #
      # @return [Array<RubyPi::Tools::Definition>] All tools in registration order.
      def all
        @mutex.synchronize { @tools.values }
      end

      # Returns the names of all registered tools. Thread-safe.
      #
      # @return [Array<Symbol>] An array of tool name symbols.
      def names
        @mutex.synchronize { @tools.keys }
      end

      # Returns the number of registered tools. Thread-safe.
      #
      # @return [Integer] The count of tools.
      def size
        @mutex.synchronize { @tools.size }
      end

      # Checks whether a tool with the given name is registered. Thread-safe.
      #
      # @param name [String, Symbol] The tool name to check.
      # @return [Boolean] true if the tool exists in the registry.
      def registered?(name)
        @mutex.synchronize { @tools.key?(name.to_sym) }
      end

      # Provides a human-readable string representation.
      #
      # @return [String] Summary of the registry contents.
      def inspect
        "#<RubyPi::Tools::Registry tools=#{names.inspect}>"
      end
    end
  end
end
