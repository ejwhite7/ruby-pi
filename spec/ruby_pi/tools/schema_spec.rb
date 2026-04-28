# frozen_string_literal: true

# spec/ruby_pi/tools/schema_spec.rb
#
# Tests for RubyPi::Schema DSL — verifies that all builder methods produce
# correct JSON Schema Draft 7 hashes, including nested objects, required
# field aggregation, enums, formats, and constraints.

require_relative "../../../lib/ruby_pi/tools/schema"

RSpec.describe RubyPi::Schema do
  describe ".string" do
    it "builds a basic string schema" do
      schema = described_class.string("A name")
      expect(schema[:type]).to eq("string")
      expect(schema[:description]).to eq("A name")
    end

    it "omits description when not provided" do
      schema = described_class.string
      expect(schema).to eq({ type: "string" })
    end

    it "includes enum when specified" do
      schema = described_class.string("Platform", enum: ["linkedin", "twitter"])
      expect(schema[:enum]).to eq(["linkedin", "twitter"])
    end

    it "includes format when specified" do
      schema = described_class.string("Datetime", format: "date-time")
      expect(schema[:format]).to eq("date-time")
    end

    it "includes minLength and maxLength" do
      schema = described_class.string("Code", min_length: 1, max_length: 10)
      expect(schema[:minLength]).to eq(1)
      expect(schema[:maxLength]).to eq(10)
    end

    it "includes pattern" do
      schema = described_class.string("Slug", pattern: "^[a-z0-9-]+$")
      expect(schema[:pattern]).to eq("^[a-z0-9-]+$")
    end

    it "sets internal _required flag when required: true" do
      schema = described_class.string("Name", required: true)
      expect(schema[:_required]).to be true
    end

    it "does not set _required when required: false (default)" do
      schema = described_class.string("Name")
      expect(schema).not_to have_key(:_required)
    end
  end

  describe ".integer" do
    it "builds a basic integer schema" do
      schema = described_class.integer("Age")
      expect(schema[:type]).to eq("integer")
      expect(schema[:description]).to eq("Age")
    end

    it "includes minimum and maximum" do
      schema = described_class.integer("Count", minimum: 0, maximum: 100)
      expect(schema[:minimum]).to eq(0)
      expect(schema[:maximum]).to eq(100)
    end

    it "includes enum" do
      schema = described_class.integer("Priority", enum: [1, 2, 3])
      expect(schema[:enum]).to eq([1, 2, 3])
    end

    it "supports required flag" do
      schema = described_class.integer("ID", required: true)
      expect(schema[:_required]).to be true
    end
  end

  describe ".number" do
    it "builds a basic number schema" do
      schema = described_class.number("Score")
      expect(schema[:type]).to eq("number")
      expect(schema[:description]).to eq("Score")
    end

    it "includes minimum and maximum" do
      schema = described_class.number("Score", minimum: 0.0, maximum: 1.0)
      expect(schema[:minimum]).to eq(0.0)
      expect(schema[:maximum]).to eq(1.0)
    end

    it "supports required flag" do
      schema = described_class.number("Rate", required: true)
      expect(schema[:_required]).to be true
    end
  end

  describe ".boolean" do
    it "builds a basic boolean schema" do
      schema = described_class.boolean("Active")
      expect(schema[:type]).to eq("boolean")
      expect(schema[:description]).to eq("Active")
    end

    it "supports required flag" do
      schema = described_class.boolean("Enabled", required: true)
      expect(schema[:_required]).to be true
    end

    it "omits description when not provided" do
      schema = described_class.boolean
      expect(schema).to eq({ type: "boolean" })
    end
  end

  describe ".array" do
    it "builds a basic array schema" do
      schema = described_class.array(description: "Tags")
      expect(schema[:type]).to eq("array")
      expect(schema[:description]).to eq("Tags")
    end

    it "includes items schema" do
      items = described_class.string("Tag")
      schema = described_class.array(items: items)
      expect(schema[:items]).to eq({ type: "string", description: "Tag" })
    end

    it "strips _required from items schema" do
      items = described_class.string("Tag", required: true)
      schema = described_class.array(items: items)
      expect(schema[:items]).not_to have_key(:_required)
    end

    it "includes minItems and maxItems" do
      schema = described_class.array(min_items: 1, max_items: 5)
      expect(schema[:minItems]).to eq(1)
      expect(schema[:maxItems]).to eq(5)
    end

    it "includes uniqueItems" do
      schema = described_class.array(unique_items: true)
      expect(schema[:uniqueItems]).to be true
    end

    it "supports required flag" do
      schema = described_class.array(required: true)
      expect(schema[:_required]).to be true
    end
  end

  describe ".object" do
    it "builds an object schema with properties" do
      schema = described_class.object(
        name: described_class.string("Name"),
        age: described_class.integer("Age")
      )

      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:name]).to eq({ type: "string", description: "Name" })
      expect(schema[:properties][:age]).to eq({ type: "integer", description: "Age" })
    end

    it "collects required fields from properties marked required: true" do
      schema = described_class.object(
        name: described_class.string("Name", required: true),
        age: described_class.integer("Age"),
        email: described_class.string("Email", required: true)
      )

      expect(schema[:required]).to contain_exactly("name", "email")
    end

    it "omits required array when no properties are required" do
      schema = described_class.object(
        name: described_class.string("Name"),
        age: described_class.integer("Age")
      )

      expect(schema).not_to have_key(:required)
    end

    it "strips _required from property schemas" do
      schema = described_class.object(
        name: described_class.string("Name", required: true)
      )

      expect(schema[:properties][:name]).not_to have_key(:_required)
    end

    it "handles nested objects" do
      schema = described_class.object(
        address: described_class.object(
          street: described_class.string("Street", required: true),
          city: described_class.string("City", required: true)
        )
      )

      address = schema[:properties][:address]
      expect(address[:type]).to eq("object")
      expect(address[:properties][:street]).to eq({ type: "string", description: "Street" })
      expect(address[:required]).to contain_exactly("street", "city")
    end

    it "handles complex mixed schemas" do
      schema = described_class.object(
        content: described_class.string("Post content", required: true),
        platform: described_class.string("Target platform", enum: ["linkedin", "twitter"]),
        scheduled_at: described_class.string("ISO8601 datetime", format: "date-time"),
        tags: described_class.array(items: described_class.string("Tag")),
        score: described_class.number("Score", minimum: 0.0, maximum: 1.0)
      )

      expect(schema[:type]).to eq("object")
      expect(schema[:required]).to eq(["content"])
      expect(schema[:properties][:platform][:enum]).to eq(["linkedin", "twitter"])
      expect(schema[:properties][:scheduled_at][:format]).to eq("date-time")
      expect(schema[:properties][:tags][:type]).to eq("array")
      expect(schema[:properties][:score][:minimum]).to eq(0.0)
    end
  end
end
