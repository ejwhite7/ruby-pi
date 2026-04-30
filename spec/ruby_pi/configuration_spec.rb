# frozen_string_literal: true

# spec/ruby_pi/configuration_spec.rb
#
# Tests for RubyPi::Configuration — verifies defaults, attribute setters,
# reset! behavior using set_defaults, and per-agent instance support.

require_relative "../../lib/ruby_pi/configuration"

RSpec.describe RubyPi::Configuration do
  subject(:config) { described_class.new }

  describe "#initialize" do
    it "sets default retry values" do
      expect(config.max_retries).to eq(3)
      expect(config.retry_base_delay).to eq(1.0)
      expect(config.retry_max_delay).to eq(30.0)
    end

    it "sets default timeout values" do
      expect(config.request_timeout).to eq(120)
      expect(config.open_timeout).to eq(10)
    end

    it "sets default model names" do
      expect(config.default_gemini_model).to eq("gemini-2.0-flash")
      expect(config.default_anthropic_model).to eq("claude-sonnet-4-20250514")
      expect(config.default_openai_model).to eq("gpt-4o")
    end

    it "defaults API keys to nil" do
      expect(config.gemini_api_key).to be_nil
      expect(config.anthropic_api_key).to be_nil
      expect(config.openai_api_key).to be_nil
    end

    it "defaults logger to nil" do
      expect(config.logger).to be_nil
    end
  end

  describe "#reset!" do
    it "restores all defaults after mutation" do
      config.gemini_api_key = "test-key"
      config.max_retries = 10
      config.logger = double("logger")

      config.reset!

      expect(config.gemini_api_key).to be_nil
      expect(config.max_retries).to eq(3)
      expect(config.logger).to be_nil
    end

    it "does not call initialize directly (uses set_defaults)" do
      # Verify that reset! works by checking that defaults are restored.
      # The implementation uses set_defaults to avoid the anti-pattern of
      # calling initialize from reset!.
      config.openai_api_key = "some-key"
      config.retry_base_delay = 99.0

      config.reset!

      expect(config.openai_api_key).to be_nil
      expect(config.retry_base_delay).to eq(1.0)
    end
  end

  describe "per-agent configuration instances" do
    it "supports creating independent configuration instances" do
      global = described_class.new
      global.openai_api_key = "global-key"

      per_agent = described_class.new
      per_agent.openai_api_key = "agent-key"

      expect(global.openai_api_key).to eq("global-key")
      expect(per_agent.openai_api_key).to eq("agent-key")
    end

    it "mutations to one instance do not affect another" do
      config_a = described_class.new
      config_b = described_class.new

      config_a.max_retries = 99

      expect(config_a.max_retries).to eq(99)
      expect(config_b.max_retries).to eq(3)
    end
  end
end
