# frozen_string_literal: true

# spec/ruby_pi/llm/model_spec.rb
#
# Tests for the Model value object and the RubyPi::LLM.model factory method.
# Validates attribute access, equality, hash behavior, and the factory's ability
# to construct provider instances from symbolic identifiers.

require "spec_helper"

RSpec.describe RubyPi::LLM::Model do
  describe "#initialize" do
    it "stores provider as a symbol and name as a string" do
      model = described_class.new(provider: "gemini", name: "gemini-2.0-flash")

      expect(model.provider).to eq(:gemini)
      expect(model.name).to eq("gemini-2.0-flash")
    end

    it "accepts symbol provider" do
      model = described_class.new(provider: :anthropic, name: "claude-sonnet-4-20250514")

      expect(model.provider).to eq(:anthropic)
      expect(model.name).to eq("claude-sonnet-4-20250514")
    end
  end

  describe "#build" do
    it "constructs a Gemini provider instance" do
      model = described_class.new(provider: :gemini, name: "gemini-2.0-flash")
      provider = model.build

      expect(provider).to be_a(RubyPi::LLM::Gemini)
      expect(provider.model_name).to eq("gemini-2.0-flash")
    end

    it "constructs an Anthropic provider instance" do
      model = described_class.new(provider: :anthropic, name: "claude-sonnet-4-20250514")
      provider = model.build

      expect(provider).to be_a(RubyPi::LLM::Anthropic)
      expect(provider.model_name).to eq("claude-sonnet-4-20250514")
    end

    it "constructs an OpenAI provider instance" do
      model = described_class.new(provider: :openai, name: "gpt-4o")
      provider = model.build

      expect(provider).to be_a(RubyPi::LLM::OpenAI)
      expect(provider.model_name).to eq("gpt-4o")
    end
  end

  describe "#to_h" do
    it "returns a hash with provider and name" do
      model = described_class.new(provider: :openai, name: "gpt-4o")

      expect(model.to_h).to eq({ provider: :openai, name: "gpt-4o" })
    end
  end

  describe "#==" do
    it "considers models with the same provider and name as equal" do
      a = described_class.new(provider: :gemini, name: "gemini-2.0-flash")
      b = described_class.new(provider: :gemini, name: "gemini-2.0-flash")

      expect(a).to eq(b)
    end

    it "considers models with different providers as not equal" do
      a = described_class.new(provider: :gemini, name: "gemini-2.0-flash")
      b = described_class.new(provider: :openai, name: "gemini-2.0-flash")

      expect(a).not_to eq(b)
    end

    it "considers models with different names as not equal" do
      a = described_class.new(provider: :openai, name: "gpt-4o")
      b = described_class.new(provider: :openai, name: "gpt-3.5-turbo")

      expect(a).not_to eq(b)
    end
  end

  describe "#hash" do
    it "produces the same hash for equal models" do
      a = described_class.new(provider: :anthropic, name: "claude-sonnet-4-20250514")
      b = described_class.new(provider: :anthropic, name: "claude-sonnet-4-20250514")

      expect(a.hash).to eq(b.hash)
    end

    it "works correctly as hash keys" do
      model_a = described_class.new(provider: :gemini, name: "gemini-2.0-flash")
      model_b = described_class.new(provider: :gemini, name: "gemini-2.0-flash")

      hash = { model_a => "value" }
      expect(hash[model_b]).to eq("value")
    end
  end

  describe "#to_s" do
    it "returns a readable string representation" do
      model = described_class.new(provider: :openai, name: "gpt-4o")

      expect(model.to_s).to include("openai")
      expect(model.to_s).to include("gpt-4o")
    end
  end
end

RSpec.describe RubyPi::LLM, ".model" do
  describe "factory method" do
    it "creates a Gemini provider" do
      provider = described_class.model(:gemini, "gemini-2.0-flash")

      expect(provider).to be_a(RubyPi::LLM::Gemini)
      expect(provider.model_name).to eq("gemini-2.0-flash")
    end

    it "creates an Anthropic provider" do
      provider = described_class.model(:anthropic, "claude-sonnet-4-20250514")

      expect(provider).to be_a(RubyPi::LLM::Anthropic)
      expect(provider.model_name).to eq("claude-sonnet-4-20250514")
    end

    it "creates an OpenAI provider" do
      provider = described_class.model(:openai, "gpt-4o")

      expect(provider).to be_a(RubyPi::LLM::OpenAI)
      expect(provider.model_name).to eq("gpt-4o")
    end

    it "accepts string provider names" do
      provider = described_class.model("gemini", "gemini-2.0-flash")

      expect(provider).to be_a(RubyPi::LLM::Gemini)
    end

    it "raises ArgumentError for unsupported providers" do
      expect { described_class.model(:cohere, "command-r") }.to raise_error(ArgumentError, /Unsupported provider/)
    end
  end
end
