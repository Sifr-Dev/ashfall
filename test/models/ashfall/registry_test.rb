# frozen_string_literal: true

require "test_helper"

module Ashfall
  class RegistryTest < ActiveSupport::TestCase
    def valid_declarations
      [
        {
          model: "User",
          column: "email",
          category: :contact,
          action: :pseudonymize,
          retention: "30 days",
          justification: nil
        },
        {
          model: "Invoice",
          column: "tax_id",
          category: :identifier,
          action: :retain,
          retention: "7 years",
          justification: "Statutory accounting record"
        }
      ]
    end

    test "builds an immutable action plan for a subject" do
      registry = Ashfall::Registry.new(valid_declarations)
      plan = registry.plan(subject: "subject-token")

      assert_equal 2, plan.length
      assert_equal :pseudonymize, plan.first[:action]
      assert_equal "subject-token", plan.first[:subject]
      assert_equal "Statutory accounting record", plan.last[:justification]
      assert plan.frozen?
      assert plan.all?(&:frozen?)
    end

    test "requires an explicit justification for retained data" do
      declarations = valid_declarations
      declarations.last[:justification] = " "
      assert_raises(Ashfall::Registry::RetentionJustificationRequired) do
        Ashfall::Registry.new(declarations)
      end
    end

    test "loads the example declaration without evaluating Ruby objects" do
      registry = Ashfall::Registry.from_yaml(Rails.root.join("config/erasure.example.yml"))
      assert_equal 2, registry.plan(subject: "example").length
    end

    test "rejects unknown actions" do
      declarations = valid_declarations
      declarations.first[:action] = :hide
      assert_raises(Ashfall::Registry::InvalidDeclaration) do
        Ashfall::Registry.new(declarations)
      end
    end

    test "rejects invalid model and column declarations" do
      declarations = valid_declarations
      declarations.first[:model] = "User; DROP TABLE users"
      assert_raises(Ashfall::Registry::InvalidDeclaration) do
        Ashfall::Registry.new(declarations)
      end

      declarations = valid_declarations
      declarations.first[:column] = "email; SELECT * FROM users"
      assert_raises(Ashfall::Registry::InvalidDeclaration) do
        Ashfall::Registry.new(declarations)
      end
    end
  end
end
