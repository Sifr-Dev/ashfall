# frozen_string_literal: true

require "test_helper"

module Ashfall
  class SchemaFingerprintTest < ActiveSupport::TestCase
    FakeModel = Data.define(:name, :column_names)

    def declarations
      [
        { model: "User", column: "email", category: :contact, action: :pseudonymize, retention: "30 days", justification: nil },
        { model: "User", column: "name", category: :contact, action: :delete, retention: "30 days", justification: nil }
      ]
    end

    test "is a stable SHA-256 digest for the same registry and columns" do
      registry = Registry.new(declarations)
      first = SchemaFingerprint.new(registry: registry, model_classes: [ FakeModel.new("User", %w[name email]) ]).to_s
      second = SchemaFingerprint.new(registry: Registry.new(declarations), model_classes: [ FakeModel.new("User", %w[email name]) ]).to_s
      assert_match ErasureReceipt::HEX64, first
      assert_equal first, second
    end

    test "changes when a column or declaration changes" do
      registry = Registry.new(declarations)
      baseline = SchemaFingerprint.new(registry: registry, model_classes: [ FakeModel.new("User", %w[email name]) ]).to_s
      added_column = SchemaFingerprint.new(registry: registry, model_classes: [ FakeModel.new("User", %w[email name nickname]) ]).to_s
      changed_action = SchemaFingerprint.new(
        registry: Registry.new(declarations.map { |d| d[:column] == "name" ? d.merge(action: :retain, justification: "Audit") : d }),
        model_classes: [ FakeModel.new("User", %w[email name]) ]
      ).to_s

      refute_equal baseline, added_column
      refute_equal baseline, changed_action
    end
  end
end
