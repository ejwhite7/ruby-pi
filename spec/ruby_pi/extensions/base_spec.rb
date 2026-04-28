# frozen_string_literal: true

# spec/ruby_pi/extensions/base_spec.rb
#
# Tests for RubyPi::Extensions::Base — verifies the hook registration DSL,
# hooks inheritance, and agent registration behavior.

require_relative "../../../lib/ruby_pi/agent/events"
require_relative "../../../lib/ruby_pi/extensions/base"

RSpec.describe RubyPi::Extensions::Base do
  # Clean up dynamically created classes between tests to avoid cross-contamination
  after(:each) do
    # Remove test constants if defined
    [:TestExtension, :ParentExtension, :ChildExtension, :GrandchildExtension].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
  end

  describe ".on_event" do
    it "registers a hook for a valid event" do
      ext = Class.new(described_class) do
        on_event :agent_end do |data, agent|
          # hook body
        end
      end

      expect(ext.hooks[:agent_end]).to be_an(Array)
      expect(ext.hooks[:agent_end].size).to eq(1)
    end

    it "registers multiple hooks for the same event" do
      ext = Class.new(described_class) do
        on_event :agent_end do |data, agent|
          "first"
        end

        on_event :agent_end do |data, agent|
          "second"
        end
      end

      expect(ext.hooks[:agent_end].size).to eq(2)
    end

    it "registers hooks for different events" do
      ext = Class.new(described_class) do
        on_event :agent_end do |data, agent|
          "end"
        end

        on_event :tool_execution_start do |data, agent|
          "start"
        end
      end

      expect(ext.hooks.keys).to include(:agent_end, :tool_execution_start)
    end

    it "raises ArgumentError for unknown event types" do
      expect {
        Class.new(described_class) do
          on_event :invalid_event do |data, agent|
            "nope"
          end
        end
      }.to raise_error(ArgumentError, /Unknown event type/)
    end
  end

  describe ".hooks" do
    it "returns an empty hash for a base class with no hooks" do
      ext = Class.new(described_class)
      expect(ext.hooks).to eq({})
    end

    it "returns registered hooks" do
      ext = Class.new(described_class) do
        on_event :error do |data, agent|
          "handle error"
        end
      end

      expect(ext.hooks[:error]).to be_an(Array)
      expect(ext.hooks[:error].size).to eq(1)
    end

    it "returns a copy (not the original)" do
      ext = Class.new(described_class) do
        on_event :agent_end do |data, agent|
          "hook"
        end
      end

      hooks_a = ext.hooks
      hooks_b = ext.hooks
      expect(hooks_a).not_to equal(hooks_b) # different object identity
    end
  end

  describe "hooks inheritance" do
    it "inherits hooks from parent class" do
      # Using Object.const_set for cleaner test class names
      parent = Class.new(described_class) do
        on_event :agent_end do |data, agent|
          "parent hook"
        end
      end
      Object.const_set(:ParentExtension, parent)

      child = Class.new(ParentExtension) do
        on_event :error do |data, agent|
          "child hook"
        end
      end
      Object.const_set(:ChildExtension, child)

      # Child should have both parent's :agent_end hook and its own :error hook
      expect(child.hooks[:agent_end]).to be_an(Array)
      expect(child.hooks[:agent_end].size).to eq(1)
      expect(child.hooks[:error]).to be_an(Array)
      expect(child.hooks[:error].size).to eq(1)
    end

    it "does not modify parent hooks when child adds hooks" do
      parent = Class.new(described_class) do
        on_event :agent_end do |data, agent|
          "parent"
        end
      end
      Object.const_set(:ParentExtension, parent)

      child = Class.new(ParentExtension) do
        on_event :agent_end do |data, agent|
          "child"
        end
      end
      Object.const_set(:ChildExtension, child)

      # Parent should still have only 1 hook
      expect(parent.hooks[:agent_end].size).to eq(1)
      # Child should have 2 (inherited + own)
      expect(child.hooks[:agent_end].size).to eq(2)
    end

    it "supports multi-level inheritance" do
      parent = Class.new(described_class) do
        on_event :agent_end do |data, agent|
          "grandparent"
        end
      end
      Object.const_set(:ParentExtension, parent)

      child = Class.new(ParentExtension) do
        on_event :turn_start do |data, agent|
          "parent"
        end
      end
      Object.const_set(:ChildExtension, child)

      grandchild = Class.new(ChildExtension) do
        on_event :error do |data, agent|
          "grandchild"
        end
      end
      Object.const_set(:GrandchildExtension, grandchild)

      hooks = grandchild.hooks
      expect(hooks[:agent_end].size).to eq(1)
      expect(hooks[:turn_start].size).to eq(1)
      expect(hooks[:error].size).to eq(1)
    end
  end

  describe "hook callables" do
    it "stores Proc objects that can be called" do
      ext = Class.new(described_class) do
        on_event :agent_end do |data, agent|
          data[:processed] = true
          data
        end
      end

      hook = ext.hooks[:agent_end].first
      expect(hook).to respond_to(:call)

      test_data = {}
      hook.call(test_data, nil)
      expect(test_data[:processed]).to be true
    end
  end
end
