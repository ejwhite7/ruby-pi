# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_14_abstract_method_error_spec.rb
#
# Tests for Issue #14: NotImplementedError renamed to AbstractMethodError

require "spec_helper"

RSpec.describe "Issue #14: AbstractMethodError replaces NotImplementedError" do
  it "defines RubyPi::AbstractMethodError" do
    expect(defined?(RubyPi::AbstractMethodError)).to eq("constant")
    expect(RubyPi::AbstractMethodError.superclass).to eq(RubyPi::Error)
  end

  it "does not define RubyPi::NotImplementedError" do
    expect(defined?(RubyPi::NotImplementedError)).to be_nil
  end

  it "does not shadow Ruby's stdlib NotImplementedError" do
    # Ruby's built-in NotImplementedError < ScriptError should still be accessible
    expect(::NotImplementedError.superclass).to eq(ScriptError)
  end

  it "creates AbstractMethodError with method name" do
    error = RubyPi::AbstractMethodError.new(:my_method)
    expect(error.message).to include("my_method")
    expect(error.message).to include("Subclass must implement")
  end

  it "creates AbstractMethodError without method name" do
    error = RubyPi::AbstractMethodError.new
    expect(error.message).to include("Subclass must implement")
  end

  describe "BaseProvider uses AbstractMethodError" do
    it "raises AbstractMethodError for model_name" do
      # Create a bare subclass that doesn't implement the required methods
      bare_provider = Class.new(RubyPi::LLM::BaseProvider)
      instance = bare_provider.new

      expect { instance.model_name }.to raise_error(RubyPi::AbstractMethodError)
    end

    it "raises AbstractMethodError for provider_name" do
      bare_provider = Class.new(RubyPi::LLM::BaseProvider)
      instance = bare_provider.new

      expect { instance.provider_name }.to raise_error(RubyPi::AbstractMethodError)
    end

    it "no longer references NotImplementedError in source" do
      source = File.read(File.expand_path("../../../lib/ruby_pi/llm/base_provider.rb", __dir__))
      expect(source).not_to include("NotImplementedError")
      expect(source).to include("AbstractMethodError")
    end
  end
end
