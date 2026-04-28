# frozen_string_literal: true

# ruby-pi.gemspec
#
# Gem specification for the ruby-pi gem. Defines metadata, dependencies,
# and packaging configuration for distribution via RubyGems.

require_relative "lib/ruby_pi/version"

Gem::Specification.new do |spec|
  spec.name          = "ruby-pi"
  spec.version       = RubyPi::VERSION
  spec.authors       = ["RubyPi Contributors"]
  spec.email         = ["ruby-pi@example.com"]

  spec.summary       = "AI agent harness for Ruby — build LLM agents with tool calling, " \
                       "streaming, and a unified interface to OpenAI, Anthropic Claude, and Google Gemini."
  spec.description   = "RubyPi is a minimal, composable AI agent harness for Ruby. " \
                       "Build production-ready LLM agents and AI agents with a unified provider " \
                       "interface across OpenAI, Anthropic Claude, and Google Gemini, plus first-class " \
                       "support for tool calling (function calling), streaming responses, automatic " \
                       "retries, provider fallback, context compaction, and a think-act-observe agent " \
                       "loop. Anti-framework design — small, idiomatic, and explicit. Ideal for " \
                       "building autonomous AI agents, ReAct agents, tool-using LLM agents, and " \
                       "chatbots in Ruby."
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.homepage      = "https://github.com/ejwhite7/ruby-pi"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ejwhite7/ruby-pi"
  spec.metadata["changelog_uri"]   = "https://github.com/ejwhite7/ruby-pi/blob/main/CHANGELOG.md"

  # Include all lib files and the gemspec itself
  spec.files = Dir.chdir(__dir__) do
    Dir["{lib}/**/*", "LICENSE", "README.md", "CHANGELOG.md"].reject { |f| File.directory?(f) }
  end

  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "faraday",          "~> 2.0"
  spec.add_dependency "faraday-retry",    "~> 2.0"
  spec.add_dependency "faraday-net_http", ">= 3.0", "< 3.4"
  spec.add_dependency "concurrent-ruby",  "~> 1.2"
  spec.add_dependency "ostruct",          "~> 0.6"

  # Development dependencies
  spec.add_development_dependency "rspec",   "~> 3.12"
  spec.add_development_dependency "webmock", "~> 3.18"
  spec.add_development_dependency "rake",    "~> 13.0"
end
