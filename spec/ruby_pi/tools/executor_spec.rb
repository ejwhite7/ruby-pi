# frozen_string_literal: true

# spec/ruby_pi/tools/executor_spec.rb
#
# Tests for RubyPi::Tools::Executor — verifies parallel execution,
# sequential execution, error handling, and timeout behavior.

require_relative "../../../lib/ruby_pi/tools/schema"
require_relative "../../../lib/ruby_pi/tools/definition"
require_relative "../../../lib/ruby_pi/tools/registry"
require_relative "../../../lib/ruby_pi/tools/result"
require_relative "../../../lib/ruby_pi/tools/executor"

RSpec.describe RubyPi::Tools::Executor do
  let(:registry) { RubyPi::Tools::Registry.new }

  let(:fast_tool) do
    RubyPi::Tools::Definition.new(
      name: "fast_tool",
      description: "Returns quickly",
      category: :test
    ) { |args| { message: "fast", input: args[:input] } }
  end

  let(:slow_tool) do
    RubyPi::Tools::Definition.new(
      name: "slow_tool",
      description: "Takes a while",
      category: :test
    ) { |_| sleep(5); { message: "slow" } }
  end

  let(:error_tool) do
    RubyPi::Tools::Definition.new(
      name: "error_tool",
      description: "Always fails",
      category: :test
    ) { |_| raise StandardError, "Something went wrong" }
  end

  let(:echo_tool) do
    RubyPi::Tools::Definition.new(
      name: "echo_tool",
      description: "Echoes input",
      category: :test
    ) { |args| args }
  end

  before do
    registry.register(fast_tool)
    registry.register(echo_tool)
  end

  describe "#initialize" do
    it "sets mode to :parallel by default" do
      executor = described_class.new(registry)
      expect(executor.mode).to eq(:parallel)
    end

    it "accepts :sequential mode" do
      executor = described_class.new(registry, mode: :sequential)
      expect(executor.mode).to eq(:sequential)
    end

    it "sets default timeout to 30 seconds" do
      executor = described_class.new(registry)
      expect(executor.timeout).to eq(30)
    end

    it "accepts custom timeout" do
      executor = described_class.new(registry, timeout: 60)
      expect(executor.timeout).to eq(60)
    end

    it "raises ArgumentError for invalid mode" do
      expect {
        described_class.new(registry, mode: :invalid)
      }.to raise_error(ArgumentError, /Mode must be/)
    end
  end

  describe "#execute (sequential)" do
    let(:executor) { described_class.new(registry, mode: :sequential) }

    it "executes a single tool call" do
      results = executor.execute([
        { name: "fast_tool", arguments: { input: "hello" } }
      ])

      expect(results.size).to eq(1)
      expect(results[0]).to be_a(RubyPi::Tools::Result)
      expect(results[0].success?).to be true
      expect(results[0].value).to eq({ message: "fast", input: "hello" })
      expect(results[0].name).to eq("fast_tool")
    end

    it "executes multiple tool calls in order" do
      results = executor.execute([
        { name: "fast_tool", arguments: { input: "first" } },
        { name: "echo_tool", arguments: { data: "second" } }
      ])

      expect(results.size).to eq(2)
      expect(results[0].value).to eq({ message: "fast", input: "first" })
      expect(results[1].value).to eq({ data: "second" })
    end

    it "returns failure result for unknown tools" do
      results = executor.execute([
        { name: "nonexistent", arguments: {} }
      ])

      expect(results[0].success?).to be false
      expect(results[0].error).to include("not found")
      expect(results[0].name).to eq("nonexistent")
    end

    it "records duration_ms for each result" do
      results = executor.execute([
        { name: "fast_tool", arguments: { input: "test" } }
      ])

      expect(results[0].duration_ms).to be >= 0
    end

    it "handles string keys in call hashes" do
      results = executor.execute([
        { "name" => "fast_tool", "arguments" => { input: "test" } }
      ])

      expect(results[0].success?).to be true
    end

    it "defaults arguments to empty hash when not provided" do
      results = executor.execute([
        { name: "echo_tool" }
      ])

      expect(results[0].success?).to be true
      expect(results[0].value).to eq({})
    end
  end

  describe "#execute (parallel)" do
    let(:executor) { described_class.new(registry, mode: :parallel) }

    it "executes multiple tool calls" do
      results = executor.execute([
        { name: "fast_tool", arguments: { input: "a" } },
        { name: "echo_tool", arguments: { key: "b" } }
      ])

      expect(results.size).to eq(2)
      expect(results[0].success?).to be true
      expect(results[1].success?).to be true
    end

    it "returns results in the same order as calls" do
      results = executor.execute([
        { name: "fast_tool", arguments: { input: "first" } },
        { name: "echo_tool", arguments: { input: "second" } }
      ])

      expect(results[0].name).to eq("fast_tool")
      expect(results[1].name).to eq("echo_tool")
    end

    it "runs tools concurrently (faster than sequential)" do
      # Register two tools that each sleep briefly
      sleep_tool_a = RubyPi::Tools::Definition.new(
        name: "sleep_a", description: "Sleeps", category: :test
      ) { |_| sleep(0.1); "a" }

      sleep_tool_b = RubyPi::Tools::Definition.new(
        name: "sleep_b", description: "Sleeps", category: :test
      ) { |_| sleep(0.1); "b" }

      registry.register(sleep_tool_a)
      registry.register(sleep_tool_b)

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = executor.execute([
        { name: "sleep_a", arguments: {} },
        { name: "sleep_b", arguments: {} }
      ])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      # Parallel should complete in ~0.1s, not ~0.2s
      expect(elapsed).to be < 0.3
      expect(results.all?(&:success?)).to be true
    end
  end

  describe "error handling" do
    before { registry.register(error_tool) }

    it "wraps tool errors in a failure Result (sequential)" do
      executor = described_class.new(registry, mode: :sequential)
      results = executor.execute([
        { name: "error_tool", arguments: {} }
      ])

      expect(results[0].success?).to be false
      expect(results[0].error).to include("Something went wrong")
      expect(results[0].error).to include("StandardError")
      expect(results[0].name).to eq("error_tool")
    end

    it "wraps tool errors in a failure Result (parallel)" do
      executor = described_class.new(registry, mode: :parallel)
      results = executor.execute([
        { name: "error_tool", arguments: {} }
      ])

      expect(results[0].success?).to be false
      expect(results[0].error).to include("Something went wrong")
    end

    it "does not let one tool error affect other tools" do
      executor = described_class.new(registry, mode: :sequential)
      results = executor.execute([
        { name: "error_tool", arguments: {} },
        { name: "fast_tool", arguments: { input: "ok" } }
      ])

      expect(results[0].success?).to be false
      expect(results[1].success?).to be true
      expect(results[1].value[:message]).to eq("fast")
    end
  end

  describe "timeout handling" do
    before { registry.register(slow_tool) }

    it "times out slow tools in sequential mode" do
      executor = described_class.new(registry, mode: :sequential, timeout: 0.1)
      results = executor.execute([
        { name: "slow_tool", arguments: {} }
      ])

      expect(results[0].success?).to be false
      expect(results[0].error).to include("timed out")
    end

    it "times out slow tools in parallel mode" do
      executor = described_class.new(registry, mode: :parallel, timeout: 0.1)
      results = executor.execute([
        { name: "slow_tool", arguments: {} }
      ])

      expect(results[0].success?).to be false
      expect(results[0].error).to include("timed out")
    end

    it "does not time out fast tools" do
      executor = described_class.new(registry, mode: :sequential, timeout: 10)
      results = executor.execute([
        { name: "fast_tool", arguments: { input: "quick" } }
      ])

      expect(results[0].success?).to be true
    end
  end
end
