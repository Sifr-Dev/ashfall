# frozen_string_literal: true

require "test_helper"

module Ashfall
  class AssociationErasureExecutionTest < ActiveSupport::TestCase
    setup do
      Note.delete_all
      User.delete_all
      @user = User.create!(email: "person@example.test", name: "Example Person", subject_ref: "subject-1")
      @note = @user.notes.create!(body: "Private body", token: "private-token")
    end

    def registry
      declarations = [
        { model: "User", column: "email", category: :contact, action: :pseudonymize, retention: "30 days", justification: nil },
        { model: "User", column: "name", category: :contact, action: :delete, retention: "30 days", justification: nil },
        { model: "User", column: "created_at", category: :metadata, action: :retain, retention: "7 years", justification: "Audit" },
        { model: "User", column: "updated_at", category: :metadata, action: :retain, retention: "7 years", justification: "Audit" },
        { model: "User", column: "subject_ref", category: :identifier, action: :pseudonymize, retention: "7 years", justification: "Audit" },
        { model: "User", column: "id", category: :identifier, action: :retain, retention: "7 years", justification: "Audit" },
        { model: "Note", column: "body", category: :content, action: :delete, retention: "30 days", justification: nil },
        { model: "Note", column: "token", category: :identifier, action: :pseudonymize, retention: "30 days", justification: nil },
        { model: "Note", column: "created_at", category: :metadata, action: :retain, retention: "7 years", justification: "Audit" },
        { model: "Note", column: "updated_at", category: :metadata, action: :retain, retention: "7 years", justification: "Audit" },
        { model: "Note", column: "user_id", category: :identifier, action: :retain, retention: "7 years", justification: "Audit" },
        { model: "Note", column: "id", category: :identifier, action: :retain, retention: "7 years", justification: "Audit" }
      ]
      Ashfall::Registry.new(declarations)
    end

    test "erases related notes in the same transaction" do
      receipt = Ashfall::AssociationErasureExecution.new(registry: registry, model_classes: [ User, Note ], secret: "test-secret").call("subject-1")
      @note.reload
      @user.reload
      assert_nil @note.body
      assert @note.token.start_with?("erased-")
      assert_nil @user.name
      assert_equal receipt[:subject], @user.subject_ref
    end

    test "rejects a missing note schema before writing" do
      declarations = registry.plan(subject: "schema").map do |declaration|
        declaration.except(:subject, :due_at).merge(column: declaration[:column] == "body" ? "missing" : declaration[:column])
      end
      bad = Ashfall::Registry.new(declarations)
      assert_raises(Ashfall::ErasureExecution::SchemaMismatch) do
        Ashfall::AssociationErasureExecution.new(registry: bad, model_classes: [ User, Note ], secret: "test-secret").call("subject-1")
      end
      assert_equal "Private body", @note.reload.body
      assert_equal "Example Person", @user.reload.name
    end
  end
end
