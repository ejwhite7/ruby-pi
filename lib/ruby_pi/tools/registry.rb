# frozen_string_literal: true

# lib/ruby_pi/tools/registry.rb
#
# RubyPi::Tools::Registry — A thread-safe store for tool definitions.
#
# The Registry holds a collection of tool definitions and provides methods
# for looking them up by name, filtering by category, and extracting subsets.
# It uses a Mutex for thread safety when registering tools concurrently.
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
      # If a tool with the same name already exists, it will be overwritten
      # and a warning is emitted to stderr.
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
            warn "RubyPi::Tools::Registry: overwriting existing tool '#{tool.name}'"
          end
          @tools[tool.name] = tool
        end

        tool
      end

      # Finds a tool by name.
      #
      # @param name [String, Symbol] The name of the tool to look up.
      # @return [RubyPi::Tools::Definition, nil] The tool, or nil if not found.
      def find(name)
        @tools[name.to_sym]
      end

      # Returns a new Registry containing only the tools with the given names.
      #
      # Tools that are not found in this registry are silently skipped.
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

      # Returns all tools that belong to the given category.
      #
      # @param category [Symbol, String] The category to filter by.
      # @return [Array<RubyPi::Tools::Definition>] Tools matching the category.
      def by_category(category)
        cat = category.to_sym
        @tools.values.select { |tool| tool.category == cat }
      end

      # Returns all registered tool definitions.
      #
      # @return [Array<RubyPi::Tools::Definition>] All tools in registration order.
      def all
        @tools.values
      end

      # Returns the names of all registered tools.
      #
      # @return [Array<Symbol>] An array of tool name symbols.
      def names
        @tools.keys
      end

      # Returns the number of registered tools.
      #
      # @return [Integer] The count of tools.
      def size
        @tools.size
      end

      # Checks whether a tool with the given name is registered.
      #
      # @param name [String, Symbol] The tool name to check.
      # @return [Boolean] true if the tool exists in the registry.
      def registered?(name)
        @tools.key?(name.to_sym)
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
