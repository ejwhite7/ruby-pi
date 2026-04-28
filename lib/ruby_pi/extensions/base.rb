# frozen_string_literal: true

# lib/ruby_pi/extensions/base.rb
#
# RubyPi::Extensions::Base — Base class for agent extensions with a hook DSL.
#
# Extensions allow external modules to tap into the agent lifecycle without
# modifying core agent code. Subclasses use the `on_event` class method to
# declare handlers for specific events. When an extension is registered with
# an agent via `agent.use(MyExtension)`, all declared hooks are automatically
# subscribed to the agent's event emitter.
#
# Hooks are inherited by subclasses, so a base extension can define common
# behavior that specialized extensions build upon.

module RubyPi
  module Extensions
    # Abstract base class for agent extensions. Subclass this and use the
    # `on_event` DSL to register lifecycle hooks.
    #
    # @example Defining an extension
    #   class AuditExtension < RubyPi::Extensions::Base
    #     on_event :tool_execution_end do |data, agent|
    #       AuditLog.record(tool: data[:tool_name], success: data[:success])
    #     end
    #
    #     on_event :agent_end do |data, agent|
    #       AuditLog.finalize(success: data[:success])
    #     end
    #
    #     def self.name
    #       "audit"
    #     end
    #   end
    #
    #   agent.use(AuditExtension)
    class Base
      class << self
        # Registers a hook for the given event type. The block receives the
        # event data hash and the agent instance when the event fires.
        #
        # @param event [Symbol] the event type to hook into (must be in Agent::EVENTS)
        # @param block [Proc] the hook handler; receives (data, agent)
        # @return [void]
        # @raise [ArgumentError] if the event type is not recognized
        def on_event(event, &block)
          unless RubyPi::Agent::EVENTS.include?(event)
            raise ArgumentError,
                  "Unknown event type: #{event.inspect}. " \
                  "Must be one of: #{RubyPi::Agent::EVENTS.join(', ')}"
          end

          own_hooks[event] ||= []
          own_hooks[event] << block
        end

        # Returns all registered hooks for this extension class, including
        # hooks inherited from parent extension classes. Each event type
        # maps to an array of callable handlers.
        #
        # @return [Hash{Symbol => Array<Proc>}] hooks keyed by event type
        def hooks
          if superclass.respond_to?(:hooks)
            # Merge parent hooks with own hooks, preserving order
            merged = superclass.hooks.dup
            own_hooks.each do |event, handlers|
              merged[event] = (merged[event] || []) + handlers
            end
            merged
          else
            own_hooks.dup
          end
        end

        # Returns the extension name. Override in subclasses to provide
        # a human-readable identifier.
        #
        # @return [String] the extension name
        def name
          super
        end

        private

        # Returns the hooks hash defined directly on this class (not
        # including inherited hooks). Used internally to separate
        # own hooks from inherited ones.
        #
        # @return [Hash{Symbol => Array<Proc>}]
        def own_hooks
          @own_hooks ||= {}
        end
      end
    end
  end
end
