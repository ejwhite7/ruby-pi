# frozen_string_literal: true

# spec/ruby_pi/fixes/issue_9_11_executor_timeout_spec.rb
#
# Tests for Issues #9, #10, #11:
# - #9: Timeout.timeout replaced with thread+join (sequential) and Future#wait (parallel)
# - #10: Future#value(timeout) nil misinterpretation fixed
# - #11: Timeout leaks — future cancellation after timeout

require_relative "../../../lib/ruby_pi/errors"
require_relative "../../../lib/ruby_pi/tools/schema"
require_relative "../../../lib/ruby_pi/tools/definition"
require_relative "../../../lib/ruby_pi/tools/registry"
require_relative "../../../lib/ruby_pi/tools/result"
require_relative "../../../lib/ruby_pi/tools/executor"

RSpec.describe "Issues #9-#11: Executor timeout safety" do
  let(:registry) { RubyPi::Tools::Registry.new }

  # Issue #9: Tool that sleeps beyond the timeout — should be caught by
  # the thread+join mechanism (sequential) or Future#wait (parallel)
  # without using Timeout.timeout.
  describe "Issue #9: Safe timeout mechanism (no Timeout.timeout)" do
    let(:slow_tool) do
      RubyPi::Tools::Definition.new(
        name: "slow_tool",
        description: "Sleeps for a while",
        category: :test
      ) { |_| sleep(5); { message: "slow" } }
    end

    before { registry.register(slow_tool) }

    it "times out in sequential mode using thread+join" do
      executor = RubyPi::Tools::Executor.new(registry, mode: :sequential, timeout: 0.1)
      results = executor.execute([{ name: "slow_tool", arguments: {} }])

      expect(results[0].success?).to be false
      expect(results[0].error).to include("timed out")
    end

    it "times out in parallel mode using Future#wait" do
      executor = RubyPi::Tools::Executor.new(registry, mode: :parallel, timeout: 0.1)
      results = executor.execute([{ name: "slow_tool", arguments: {} }])

      expect(results[0].success?).to be false
      expect(results[0].error).to include("timed out")
    end

    it "does not use Timeout.timeout (verified by source inspection)" do
      source = File.read(File.expand_path("../../../lib/ruby_pi/tools/executor.rb", __dir__))
      # Should not contain any calls to Timeout.timeout
      expect(source).not_to include("Timeout.timeout")
    end

    it "has require 'concurrent' but not require 'timeout'" do
      source = File.read(File.expand_path("../../../lib/ruby_pi/tools/executor.rb", __dir__))
      expect(source).to include('require "concurrent"')
      # Timeout.timeout is unsafe — we should not require or use it
      expect(source).not_to match(/^require\s+["']timeout["']/)
    end
  end

  # Issue #10: A tool returning nil should NOT be reported as timed out
  describe "Issue #10: nil return value vs timeout distinction" do
    let(:nil_tool) do
      RubyPi::Tools::Definition.new(
        name: "nil_tool",
        description: "Returns nil",
        category: :test
      ) { |_| nil }
    end

    before { registry.register(nil_tool) }

    it "treats nil return as success in parallel mode" do
      executor = RubyPi::Tools::Executor.new(registry, mode: :parallel, timeout: 5)
      results = executor.execute([{ name: "nil_tool", arguments: {} }])

      expect(results[0].success?).to be true
      expect(results[0].value).to be_nil
      expect(results[0].error).to be_nil
    end

    it "treats nil return as success in sequential mode" do
      executor = RubyPi::Tools::Executor.new(registry, mode: :sequential, timeout: 5)
      results = executor.execute([{ name: "nil_tool", arguments: {} }])

      expect(results[0].success?).to be true
      expect(results[0].value).to be_nil
      expect(results[0].error).to be_nil
    end

    it "treats false return as success in parallel mode" do
      false_tool = RubyPi::Tools::Definition.new(
        name: "false_tool", description: "Returns false", category: :test
      ) { |_| false }
      registry.register(false_tool)

      executor = RubyPi::Tools::Executor.new(registry, mode: :parallel, timeout: 5)
      results = executor.execute([{ name: "false_tool", arguments: {} }])

      expect(results[0].success?).to be true
      expect(results[0].value).to eq(false)
    end
  end

  # Issue #11: After timeout, the future should be cancelled if possible
  describe "Issue #11: Future cancellation after timeout" do
    it "attempts to cancel the future after timeout in parallel mode" do
      slow_tool = RubyPi::Tools::Definition.new(
        name: "slow_cancel",
        description: "Very slow",
        category: :test
      ) { |_| sleep(10); "done" }
      registry.register(slow_tool)

      executor = RubyPi::Tools::Executor.new(registry, mode: :parallel, timeout: 0.1)

      # The executor should complete quickly (not wait for the slow tool)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = executor.execute([{ name: "slow_cancel", arguments: {} }])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      expect(results[0].success?).to be false
      expect(results[0].error).to include("timed out")
      expect(elapsed).to be < 1.0 # Should not wait for the full 10s
    end
  end
end
