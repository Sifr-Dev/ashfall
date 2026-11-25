# frozen_string_literal: true

require "test_helper"

module Ashfall
  class SchemaAuditTest < ActiveSupport::TestCase
    FakeModel = Data.define(:name, :column_names)

    def declarations
      [
        { model: "User", column: "email", category: :contact, action: :pseudonymize, retention: "30 days", justification: nil },
        { model: "User", column: "name", category: :contact, action: :delete, retention: "30 days", justification: nil },
        { model: "User", column: "phone", category: :contact, action: :delete, retention: "30 days", justification: nil },
        { model: "LegacyUser", column: "email", category: :contact, action: :delete, retention: "30 days", justification: nil },
        { model: "User", column: "nickname", category: :content, action: :delete, retention: "30 days", justification: nil }
      ]
    end

    test "reports every schema coverage gap without executing queries" do
      models = [ FakeModel.new("User", %w[email name created_at]) ]
      findings = Ashfall::SchemaAudit.new(Ashfall::Registry.new(declarations), models).findings

      assert_equal [
        [ :unknown_model, "LegacyUser", "email" ],
        [ :unknown_column, "User", "nickname" ],
        [ :unknown_column, "User", "phone" ],
        [ :undeclared_column, "User", "created_at" ]
      ], findings.map { |f| [ f.kind, f.model, f.column ] }
    end

    test "a fully declared model has no findings" do
      registry = Ashfall::Registry.new(declarations.first(2))
      models = [ FakeModel.new("User", %w[email name]) ]
      assert_empty Ashfall::SchemaAudit.new(registry, models).findings
    end
  end
end
