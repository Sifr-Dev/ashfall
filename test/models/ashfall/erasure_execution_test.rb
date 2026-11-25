# frozen_string_literal: true

module Ashfall
  class ErasureExecutionTest < ActiveSupport::TestCase
    def declarations(extra: [])
      [
        { model: "User", column: "email", category: :contact, action: :pseudonymize, retention: "30 days", justification: nil },
        { model: "User", column: "name", category: :contact, action: :delete, retention: "30 days", justification: nil },
        { model: "User", column: "created_at", category: :metadata, action: :retain, retention: "7 years", justification: "Audit record" },
        { model: "User", column: "updated_at", category: :metadata, action: :retain, retention: "7 years", justification: "Audit record" },
        { model: "User", column: "subject_ref", category: :identifier, action: :pseudonymize, retention: "7 years", justification: "Pseudonymous audit linkage" },
        { model: "User", column: "id", category: :identifier, action: :retain, retention: "7 years", justification: "Primary key is required for a verifiable audit record" }
      ] + extra
    end

    def registry(extra: [])
      Ashfall::Registry.new(declarations(extra: extra))
    end

    def execution(extra: [])
      Ashfall::ErasureExecution.new(registry: registry(extra: extra), model_classes: [ User ], secret: "test-secret")
    end

    setup do
      User.delete_all
      @user = User.create!(email: "person@example.test", name: "Example Person", subject_ref: "subject-1")
    end

    test "applies actions transactionally and returns a pseudonymous receipt" do
      receipt = execution.call("subject-1")
      @user.reload
      assert_nil @user.name
      assert @user.email.start_with?("erased-")
      refute_equal "person@example.test", @user.email
      refute_equal "subject-1", receipt[:subject]
      assert_equal :deleted, receipt[:actions].find { |a| a[:column] == "name" }[:action]
      assert_equal :pseudonymized, receipt[:actions].find { |a| a[:column] == "subject_ref" }[:action]
      assert_equal receipt[:subject], @user.subject_ref
      refute_equal "subject-1", @user.subject_ref
      assert receipt[:schema_fingerprint].match?(/\A[0-9a-f]{64}\z/)
      assert receipt.frozen?
      assert receipt[:actions].all?(&:frozen?)
    end

    test "pseudonymization is deterministic and allows a repeat lookup" do
      first = execution.call("subject-1")[:subject]
      second = execution.call(first)[:subject]
      assert_equal first, second
      assert_equal first, @user.reload.subject_ref
    end

    test "schema gaps fail before writing" do
      original = @user.email
      assert_raises(Ashfall::ErasureExecution::SchemaMismatch) do
        execution(extra: [ { model: "User", column: "phone", category: :contact, action: :delete, retention: "30 days", justification: nil } ]).call("subject-1")
      end
      assert_equal original, @user.reload.email
      assert_equal "Example Person", @user.name
    end

    test "unknown subject is rejected" do
      assert_raises(ActiveRecord::RecordNotFound) { execution.call("missing") }
      assert_equal "person@example.test", @user.reload.email
    end

    test "a failed later action rolls back earlier changes" do
      service = execution
      failing = service
      def failing.pseudonym(_user, _column)
        raise "simulated write failure"
      end
      assert_raises(RuntimeError) { failing.call("subject-1") }
      assert_equal "person@example.test", @user.reload.email
      assert_equal "Example Person", @user.name
    end

    test "secret is required" do
      assert_raises(Ashfall::ErasureExecution::ConfigurationError) do
        Ashfall::ErasureExecution.new(registry: registry, model_classes: [ User ], secret: "")
      end
    end
  end
end
