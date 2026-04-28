# frozen_string_literal: true

# spec/ruby_pi/tools/registry_spec.rb
#
# Tests for RubyPi::Tools::Registry — verifies registration, lookup,
# filtering, subset creation, and error handling.

require_relative "../../../lib/ruby_pi/tools/schema"
require_relative "../../../lib/ruby_pi/tools/definition"
require_relative "../../../lib/ruby_pi/tools/registry"

RSpec.describe RubyPi::Tools::Registry do
  let(:registry) { described_class.new }

  let(:create_post) do
    RubyPi::Tools::Definition.new(
      name: "create_post",
      description: "Creates a post",
      category: :content
    ) { |_| { post_id: "123" } }
  end

  let(:get_analytics) do
    RubyPi::Tools::Definition.new(
      name: "get_analytics",
      description: "Gets analytics",
      category: :analytics
    ) { |_| { views: 100 } }
  end

  let(:schedule_post) do
    RubyPi::Tools::Definition.new(
      name: "schedule_post",
      description: "Schedules a post",
      category: :content
    ) { |_| { scheduled: true } }
  end

  describe "#register" do
    it "registers a tool definition" do
      registry.register(create_post)
      expect(registry.size).to eq(1)
    end

    it "returns the registered tool" do
      result = registry.register(create_post)
      expect(result).to eq(create_post)
    end

    it "overwrites existing tool with same name and warns" do
      registry.register(create_post)
      replacement = RubyPi::Tools::Definition.new(
        name: "create_post",
        description: "Replacement",
        category: :other
      ) { |_| nil }

      expect { registry.register(replacement) }.to output(/overwriting/).to_stderr
      expect(registry.find(:create_post).description).to eq("Replacement")
      expect(registry.size).to eq(1)
    end

    it "raises ArgumentError for non-Definition objects" do
      expect {
        registry.register("not a tool")
      }.to raise_error(ArgumentError, /Expected a RubyPi::Tools::Definition/)
    end

    it "raises ArgumentError for nil" do
      expect {
        registry.register(nil)
      }.to raise_error(ArgumentError)
    end
  end

  describe "#find" do
    before do
      registry.register(create_post)
      registry.register(get_analytics)
    end

    it "finds a tool by symbol name" do
      expect(registry.find(:create_post)).to eq(create_post)
    end

    it "finds a tool by string name" do
      expect(registry.find("create_post")).to eq(create_post)
    end

    it "returns nil for unknown tools" do
      expect(registry.find(:nonexistent)).to be_nil
    end
  end

  describe "#subset" do
    before do
      registry.register(create_post)
      registry.register(get_analytics)
      registry.register(schedule_post)
    end

    it "returns a new registry with only the specified tools" do
      sub = registry.subset([:create_post, :get_analytics])
      expect(sub.size).to eq(2)
      expect(sub.names).to contain_exactly(:create_post, :get_analytics)
    end

    it "silently skips unknown tool names" do
      sub = registry.subset([:create_post, :nonexistent])
      expect(sub.size).to eq(1)
      expect(sub.names).to eq([:create_post])
    end

    it "accepts string names" do
      sub = registry.subset(["create_post"])
      expect(sub.size).to eq(1)
    end

    it "returns an empty registry for empty input" do
      sub = registry.subset([])
      expect(sub.size).to eq(0)
    end
  end

  describe "#by_category" do
    before do
      registry.register(create_post)
      registry.register(get_analytics)
      registry.register(schedule_post)
    end

    it "returns tools matching the category" do
      content_tools = registry.by_category(:content)
      expect(content_tools.size).to eq(2)
      expect(content_tools.map(&:name)).to contain_exactly(:create_post, :schedule_post)
    end

    it "accepts string categories" do
      analytics_tools = registry.by_category("analytics")
      expect(analytics_tools.size).to eq(1)
      expect(analytics_tools.first.name).to eq(:get_analytics)
    end

    it "returns empty array for unknown category" do
      expect(registry.by_category(:unknown)).to eq([])
    end
  end

  describe "#all" do
    it "returns all registered tools" do
      registry.register(create_post)
      registry.register(get_analytics)
      expect(registry.all.size).to eq(2)
    end

    it "returns empty array when no tools registered" do
      expect(registry.all).to eq([])
    end
  end

  describe "#names" do
    it "returns all tool names as symbols" do
      registry.register(create_post)
      registry.register(get_analytics)
      expect(registry.names).to contain_exactly(:create_post, :get_analytics)
    end

    it "returns empty array when no tools registered" do
      expect(registry.names).to eq([])
    end
  end

  describe "#size" do
    it "returns 0 for empty registry" do
      expect(registry.size).to eq(0)
    end

    it "tracks registrations" do
      registry.register(create_post)
      expect(registry.size).to eq(1)
      registry.register(get_analytics)
      expect(registry.size).to eq(2)
    end
  end

  describe "#registered?" do
    before { registry.register(create_post) }

    it "returns true for registered tools" do
      expect(registry.registered?(:create_post)).to be true
    end

    it "accepts string names" do
      expect(registry.registered?("create_post")).to be true
    end

    it "returns false for unregistered tools" do
      expect(registry.registered?(:nonexistent)).to be false
    end
  end

  describe "#inspect" do
    it "includes tool names" do
      registry.register(create_post)
      expect(registry.inspect).to include("create_post")
    end
  end
end
