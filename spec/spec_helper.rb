# frozen_string_literal: true

# spec/spec_helper.rb
#
# RSpec configuration and shared setup for the ruby-pi test suite. Configures
# WebMock to block all real HTTP requests and sets up RubyPi with test API keys.

require "webmock/rspec"
require "json"
require_relative "../lib/ruby_pi"

# Disable all external HTTP connections during tests
WebMock.disable_net_connect!

RSpec.configure do |config|
  # Enable focused filtering with `fit`, `fdescribe`, `fcontext`
  config.filter_run_when_matching :focus

  # Consistent ordering for reproducible results
  config.order = :random
  Kernel.srand config.seed

  # Reset RubyPi configuration before each test to prevent leakage
  config.before(:each) do
    RubyPi.reset_configuration!
    RubyPi.configure do |c|
      c.gemini_api_key   = "test-gemini-key"
      c.anthropic_api_key = "test-anthropic-key"
      c.openai_api_key   = "test-openai-key"
      c.max_retries      = 3
      c.retry_base_delay = 0.01  # Fast retries for tests
      c.retry_max_delay  = 0.05
    end
  end

  # Use expect syntax exclusively
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  # Use verifying doubles for stricter mocking
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
