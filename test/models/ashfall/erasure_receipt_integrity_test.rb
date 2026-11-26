# frozen_string_literal: true

require "test_helper"

module Ashfall
  # These tests exercise the PostgreSQL boundary directly. Active Record model
  # guards are covered in ReceiptStoreTest; here every assertion goes through
  # raw SQL so a schema.rb-only database that lost the constraints or triggers
  # would fail.
  class ErasureReceiptIntegrityTest < ActiveSupport::TestCase
    setup do
      @connection = ActiveRecord::Base.connection
      @table = @connection.quote_table_name("erasure_receipts")
      @receipt = ReceiptStore.new(secret: "test-secret").record(
        subject_token: SubjectToken.derive(secret: "test-secret", subject_ref: "subject-1"),
        model: "User",
        schema_fingerprint: "c" * 64,
        actions: [ { column: "email", action: "pseudonymized" } ],
        completed_at: Time.utc(2026, 1, 1, 12)
      )
    end

    # A rejected statement aborts the surrounding PostgreSQL transaction. Put
    # each destructive probe in a savepoint so its rollback preserves the fixture
    # and leaves the test transaction usable for the assertions that follow.
    def expect_rejected_sql(exception = ActiveRecord::StatementInvalid)
      @connection.execute("SAVEPOINT ashfall_receipt_probe")
      yield
      raise "expected the database to reject this statement"
    rescue exception
      @connection.execute("ROLLBACK TO SAVEPOINT ashfall_receipt_probe")
    ensure
      @connection.execute("RELEASE SAVEPOINT ashfall_receipt_probe")
    end

    test "the schema and triggers exist in the database" do
      triggers = @connection.select_values(<<~SQL)
        SELECT tgname FROM pg_trigger
        WHERE tgrelid = 'erasure_receipts'::regclass AND NOT tgisinternal
        ORDER BY tgname
      SQL
      indexes = @connection.select_values(<<~SQL)
        SELECT indexname FROM pg_indexes WHERE tablename = 'erasure_receipts' AND indexdef LIKE '%UNIQUE%'
        ORDER BY indexname
      SQL

      assert_includes triggers, "erasure_receipts_row_append_only"
      assert_includes triggers, "erasure_receipts_truncate_guard"
      assert_includes indexes, "index_erasure_receipts_on_plan_key"
      assert_includes indexes, "index_erasure_receipts_on_idempotency_key"
    end

    test "direct SQL update and delete are rejected" do
      expect_rejected_sql { @connection.execute("UPDATE #{@table} SET model = 'Note' WHERE id = #{@receipt.id}") }
      expect_rejected_sql { @connection.execute("DELETE FROM #{@table} WHERE id = #{@receipt.id}") }

      assert_equal "User", @receipt.reload.model
    end

    test "truncating a table that holds evidence is rejected" do
      expect_rejected_sql { @connection.execute("TRUNCATE #{@table}") }

      assert_equal 1, ErasureReceipt.count
    end

    test "check constraints reject malformed evidence even by raw SQL" do
      expect_rejected_sql do
        @connection.execute(<<~SQL)
          INSERT INTO #{@table}
            (subject_token, model, schema_fingerprint, idempotency_key, actions, completed_at, fingerprint, signature, created_at, updated_at)
          VALUES
            ('person@example.test', 'User', '#{"d" * 64}', 'raw-insert-0001', '[]', NOW(), '#{"e" * 64}', '#{"f" * 64}', NOW(), NOW())
        SQL
      end

      assert_equal 1, ErasureReceipt.count
    end

    test "the plan key is enforced by the database, not only by Ruby" do
      expect_rejected_sql(ActiveRecord::RecordNotUnique) do
        @connection.execute(<<~SQL)
          INSERT INTO #{@table}
            (subject_token, model, schema_fingerprint, idempotency_key, actions, completed_at, fingerprint, signature, created_at, updated_at)
          VALUES
            ('#{@receipt.subject_token}', 'User', '#{@receipt.schema_fingerprint}', 'raw-insert-0002', '[]', NOW(), '#{"e" * 64}', '#{"f" * 64}', NOW(), NOW())
        SQL
      end
    end

    test "there is no route that erases, reads, or deletes receipts" do
      paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

      assert_empty paths.grep(/erasure|receipt|ashfall/)
    end
  end
end
