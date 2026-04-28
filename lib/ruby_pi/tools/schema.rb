# frozen_string_literal: true

# lib/ruby_pi/tools/schema.rb
#
# RubyPi::Schema — A DSL for building JSON Schema Draft 7 hashes.
#
# This module provides a fluent, Ruby-idiomatic interface for constructing
# JSON Schema objects used to describe tool parameters. Each builder method
# (`.string`, `.integer`, `.number`, `.boolean`, `.array`, `.object`) returns
# a plain Ruby hash that conforms to JSON Schema Draft 7.
#
# The `required: true` option on individual property builders is a metadata
# flag consumed by `.object` to populate the top-level "required" array.
# It is stripped from the property's own schema hash before inclusion.
#
# Usage:
#   schema = RubyPi::Schema.object(
#     name: RubyPi::Schema.string("User's name", required: true),
#     age:  RubyPi::Schema.integer("User's age", minimum: 0)
#   )
#
# Produces:
#   {
#     type: "object",
#     properties: {
#       name: { type: "string", description: "User's name" },
#       age:  { type: "integer", description: "User's age", minimum: 0 }
#     },
#     required: ["name"]
#   }

module RubyPi
  module Schema
    class << self
      # Builds a JSON Schema for a string property.
      #
      # @param description [String] Human-readable description of the property.
      # @param required [Boolean] Whether this property is required (used by `.object`).
      # @param enum [Array<String>, nil] Allowed values for the string.
      # @param format [String, nil] JSON Schema format hint (e.g. "date-time", "email").
      # @param min_length [Integer, nil] Minimum string length.
      # @param max_length [Integer, nil] Maximum string length.
      # @param pattern [String, nil] Regex pattern the string must match.
      # @return [Hash] A JSON Schema hash for a string type.
      def string(description = nil, required: false, enum: nil, format: nil,
                 min_length: nil, max_length: nil, pattern: nil)
        schema = { type: "string" }
        schema[:description] = description if description
        schema[:enum] = enum if enum
        schema[:format] = format if format
        schema[:minLength] = min_length if min_length
        schema[:maxLength] = max_length if max_length
        schema[:pattern] = pattern if pattern
        schema[:_required] = true if required
        schema
      end

      # Builds a JSON Schema for an integer property.
      #
      # @param description [String] Human-readable description.
      # @param required [Boolean] Whether this property is required.
      # @param minimum [Integer, nil] Minimum value (inclusive).
      # @param maximum [Integer, nil] Maximum value (inclusive).
      # @param enum [Array<Integer>, nil] Allowed integer values.
      # @return [Hash] A JSON Schema hash for an integer type.
      def integer(description = nil, required: false, minimum: nil, maximum: nil, enum: nil)
        schema = { type: "integer" }
        schema[:description] = description if description
        schema[:minimum] = minimum if minimum
        schema[:maximum] = maximum if maximum
        schema[:enum] = enum if enum
        schema[:_required] = true if required
        schema
      end

      # Builds a JSON Schema for a number (float/decimal) property.
      #
      # @param description [String] Human-readable description.
      # @param required [Boolean] Whether this property is required.
      # @param minimum [Numeric, nil] Minimum value (inclusive).
      # @param maximum [Numeric, nil] Maximum value (inclusive).
      # @param enum [Array<Numeric>, nil] Allowed numeric values.
      # @return [Hash] A JSON Schema hash for a number type.
      def number(description = nil, required: false, minimum: nil, maximum: nil, enum: nil)
        schema = { type: "number" }
        schema[:description] = description if description
        schema[:minimum] = minimum if minimum
        schema[:maximum] = maximum if maximum
        schema[:enum] = enum if enum
        schema[:_required] = true if required
        schema
      end

      # Builds a JSON Schema for a boolean property.
      #
      # @param description [String] Human-readable description.
      # @param required [Boolean] Whether this property is required.
      # @return [Hash] A JSON Schema hash for a boolean type.
      def boolean(description = nil, required: false)
        schema = { type: "boolean" }
        schema[:description] = description if description
        schema[:_required] = true if required
        schema
      end

      # Builds a JSON Schema for an array property.
      #
      # @param description [String, nil] Human-readable description.
      # @param required [Boolean] Whether this property is required.
      # @param items [Hash, nil] JSON Schema hash describing each array element.
      # @param min_items [Integer, nil] Minimum number of items.
      # @param max_items [Integer, nil] Maximum number of items.
      # @param unique_items [Boolean, nil] Whether items must be unique.
      # @return [Hash] A JSON Schema hash for an array type.
      def array(description: nil, required: false, items: nil,
                min_items: nil, max_items: nil, unique_items: nil)
        schema = { type: "array" }
        schema[:description] = description if description
        # Strip internal _required flag from item schemas if present
        schema[:items] = sanitize(items) if items
        schema[:minItems] = min_items if min_items
        schema[:maxItems] = max_items if max_items
        schema[:uniqueItems] = unique_items unless unique_items.nil?
        schema[:_required] = true if required
        schema
      end

      # Builds a JSON Schema for an object with named properties.
      #
      # Each keyword argument key is a property name, and its value is a schema
      # hash produced by one of the other builder methods (`.string`, `.integer`,
      # etc.). Properties marked with `required: true` are collected into the
      # top-level "required" array.
      #
      # @param properties [Hash{Symbol => Hash}] Property name to schema mappings.
      # @return [Hash] A JSON Schema hash for an object type.
      def object(**properties)
        required_fields = []
        cleaned_properties = {}

        properties.each do |name, prop_schema|
          # Extract and consume the internal _required flag
          if prop_schema[:_required]
            required_fields << name.to_s
          end
          # Store a sanitized copy (without _required) under the property name
          cleaned_properties[name] = sanitize(prop_schema)
        end

        schema = {
          type: "object",
          properties: cleaned_properties
        }
        schema[:required] = required_fields unless required_fields.empty?
        schema
      end

      private

      # Removes internal metadata keys (prefixed with underscore) from a schema hash.
      # Returns a new hash without mutating the original.
      #
      # @param schema [Hash] A schema hash potentially containing internal keys.
      # @return [Hash] A clean copy suitable for JSON Schema output.
      def sanitize(schema)
        schema.reject { |key, _| key.to_s.start_with?("_") }
      end
    end
  end
end
