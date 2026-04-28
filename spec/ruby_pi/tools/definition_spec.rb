# frozen_string_literal: true

# spec/ruby_pi/tools/definition_spec.rb
#
# Tests for RubyPi::Tools::Definition — verifies tool creation, invocation,
# and format conversions for Gemini, Anthropic, and OpenAI APIs.

require_relative "../../../lib/ruby_pi/tools/schema"
require_relative "../../../lib/ruby_pi/tools/definition"

RSpec.describe RubyPi::Tools::Definition do
  let(:parameters) do
    RubyPi::Schema.object(
      content: RubyPi::Schema.string("Post content", required: true),
      platform: RubyPi::Schema.string("Target platform", enum: ["linkedin", "twitter"])
    )
  end

  let(:tool) do
    described_class.new(
      name: "create_post",
      description: "Creates a social media post",
      category: :content,
      parameters: parameters
    ) { |args| { post_id: "123", status: "created", content: args[:content] } }
  end

  describe "#initialize" do
    it "sets all attributes correctly" do
      expect(tool.name).to eq(:create_post)
      expect(tool.description).to eq("Creates a social media post")
      expect(tool.category).to eq(:content)
      expect(tool.parameters[:type]).to eq("object")
    end

    it "converts string name to symbol" do
      t = described_class.new(name: "my_tool", description: "Test") { |_| nil }
      expect(t.name).to eq(:my_tool)
    end

    it "converts string category to symbol" do
      t = described_class.new(name: "t", description: "Test", category: "utils") { |_| nil }
      expect(t.category).to eq(:utils)
    end

    it "allows nil category" do
      t = described_class.new(name: "t", description: "Test") { |_| nil }
      expect(t.category).to be_nil
    end

    it "defaults parameters to empty hash" do
      t = described_class.new(name: "t", description: "Test") { |_| nil }
      expect(t.parameters).to eq({})
    end

    it "raises ArgumentError when name is missing" do
      expect {
        described_class.new(name: nil, description: "Test") { |_| nil }
      }.to raise_error(ArgumentError, /name is required/)
    end

    it "raises ArgumentError when name is blank" do
      expect {
        described_class.new(name: "  ", description: "Test") { |_| nil }
      }.to raise_error(ArgumentError, /name is required/)
    end

    it "raises ArgumentError when description is missing" do
      expect {
        described_class.new(name: "t", description: nil) { |_| nil }
      }.to raise_error(ArgumentError, /description is required/)
    end

    it "raises ArgumentError when no block given" do
      expect {
        described_class.new(name: "t", description: "Test")
      }.to raise_error(ArgumentError, /block is required/)
    end
  end

  describe "#call" do
    it "invokes the implementation block with arguments" do
      result = tool.call(content: "Hello world")
      expect(result).to eq({ post_id: "123", status: "created", content: "Hello world" })
    end

    it "passes an empty hash by default" do
      t = described_class.new(name: "echo", description: "Echo") { |args| args }
      expect(t.call).to eq({})
    end
  end

  describe "#to_gemini_format" do
    it "returns Gemini function declaration format" do
      fmt = tool.to_gemini_format
      expect(fmt[:name]).to eq("create_post")
      expect(fmt[:description]).to eq("Creates a social media post")
      expect(fmt[:parameters]).to eq(parameters)
    end

    it "omits parameters when empty" do
      t = described_class.new(name: "ping", description: "Ping") { |_| "pong" }
      fmt = t.to_gemini_format
      expect(fmt).not_to have_key(:parameters)
    end
  end

  describe "#to_anthropic_format" do
    it "returns Anthropic tool format" do
      fmt = tool.to_anthropic_format
      expect(fmt[:name]).to eq("create_post")
      expect(fmt[:description]).to eq("Creates a social media post")
      expect(fmt[:input_schema]).to eq(parameters)
    end

    it "omits input_schema when parameters are empty" do
      t = described_class.new(name: "ping", description: "Ping") { |_| "pong" }
      fmt = t.to_anthropic_format
      expect(fmt).not_to have_key(:input_schema)
    end
  end

  describe "#to_openai_format" do
    it "returns OpenAI function format" do
      fmt = tool.to_openai_format
      expect(fmt[:type]).to eq("function")
      expect(fmt[:function][:name]).to eq("create_post")
      expect(fmt[:function][:description]).to eq("Creates a social media post")
      expect(fmt[:function][:parameters]).to eq(parameters)
    end

    it "omits parameters when empty" do
      t = described_class.new(name: "ping", description: "Ping") { |_| "pong" }
      fmt = t.to_openai_format
      expect(fmt[:function]).not_to have_key(:parameters)
    end
  end

  describe "#inspect" do
    it "returns a readable string" do
      expect(tool.inspect).to include("create_post")
      expect(tool.inspect).to include("content")
    end
  end
end

RSpec.describe RubyPi::Tool do
  describe ".define" do
    it "creates a Definition instance" do
      tool = described_class.define(
        name: "test_tool",
        description: "A test tool",
        category: :testing
      ) { |args| args }

      expect(tool).to be_a(RubyPi::Tools::Definition)
      expect(tool.name).to eq(:test_tool)
      expect(tool.category).to eq(:testing)
    end

    it "passes parameters through" do
      params = RubyPi::Schema.object(
        q: RubyPi::Schema.string("Query", required: true)
      )
      tool = described_class.define(
        name: "search",
        description: "Search",
        parameters: params
      ) { |_| nil }

      expect(tool.parameters).to eq(params)
    end
  end
end
