# frozen_string_literal: true

require "test_helper"

module Ashfall
  # Exercises Ashfall::DueForErasure against real persisted receipts.
  #
  # These are integration tests, not unit tests: every assertion reads rows that
  # were written through ReceiptStore into PostgreSQL and then re-loaded, so the
  # microsecond timestamp rounding, the JSONB action round-trip, and the HMAC
  # verification all run against the database rather than an in-memory double.
  class DueForErasureTest < ActiveSupport::TestCase
    SECRET = "test-secret"

    def declarations(retention: "30 days", model: "User")
      [
        { model: model, column: "email", category: :contact, action: :pseudonymize, retention: retention, justification: nil }
      ]
    end

    def registry(retention: "30 days", model: "User")
      Registry.new(declarations(retention: retention, model: model))
    end

    def store
      @store ||= ReceiptStore.new(secret: SECRET)
    end

    def record(subject_ref:, completed_at:, model: "User", actions: nil)
      subject_token = SubjectToken.derive(secret: SECRET, subject_ref: subject_ref)
      store.record(
        subject_token: subject_token,
        model: model,
        schema_fingerprint: Digest::SHA256.hexdigest("schema:#{model}"),
        actions: actions || [ { column: "email", action: "pseudonymized" } ],
        completed_at: completed_at
      )
    end

    # The append-only trigger rejects UPDATE, so the realistic way an
    # unverifiable row reaches the table is a writer that bypassed the store
    # (a restored dump, a manual INSERT). Insert one that satisfies every check
    # constraint but whose digests cannot match its payload.
    def insert_unverifiable(subject_ref:)
      subject_token = SubjectToken.derive(secret: SECRET, subject_ref: subject_ref)
      ActiveRecord::Base.connection.execute(<<~SQL)
        INSERT INTO erasure_receipts
          (subject_token, model, schema_fingerprint, idempotency_key, actions, completed_at, fingerprint, signature, created_at, updated_at)
        VALUES
          ('#{subject_token}', 'User', '#{"a" * 64}', 'bypass-insert-0001',
           '[{"column":"email","action":"pseudonymized"}]'::jsonb, '2026-01-01 00:00:00',
           '#{"e" * 64}', '#{"f" * 64}', NOW(), NOW())
      SQL
      ErasureReceipt.find_by!(idempotency_key: "bypass-insert-0001")
    end

    test "reports receipts whose retention has elapsed and excludes future ones" do
      due = record(subject_ref: "subject-due", completed_at: Time.utc(2026, 1, 1, 0, 0, 0))
      not_due = record(subject_ref: "subject-future", completed_at: Time.utc(2026, 2, 1, 0, 0, 0))

      report = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 2, 15, 0, 0, 0)).call

      assert_equal [ due.subject_token ], report.entries.map(&:subject_token)
      refute_includes report.entries.map(&:subject_token), not_due.subject_token
      assert_predicate report, :complete?
      assert_equal 1, report.due_count
    end

    test "computes the due date from the longest declared retention and the stored completion time" do
      receipt = record(subject_ref: "subject-long", completed_at: Time.utc(2026, 1, 1, 12, 30, 15, 123_456))
      now = Time.utc(2026, 3, 1, 0, 0, 0)

      report = DueForErasure.new(registry: registry(retention: "30 days"), secret: SECRET, now: now).call

      assert_equal 1, report.entries.length
      entry = report.entries.first
      assert_equal Time.utc(2026, 1, 31, 12, 30, 15, 123_456), entry.due_at
      assert_equal receipt.completed_at, entry.completed_at
      assert_equal "30 days", entry.retention
      assert_equal receipt.subject_token, entry.subject_token
      assert_equal "User", entry.model
      assert_equal receipt.schema_fingerprint, entry.schema_fingerprint
    end

    test "becomes due exactly at the boundary instant and not one microsecond earlier" do
      completed = Time.utc(2026, 1, 1, 0, 0, 0)
      record(subject_ref: "subject-boundary", completed_at: completed)
      due_at = completed + RetentionPeriod.parse("30 days").seconds

      before = DueForErasure.new(registry: registry, secret: SECRET, now: due_at - 1).call
      at = DueForErasure.new(registry: registry, secret: SECRET, now: due_at).call

      assert_empty before.entries
      assert_equal 1, at.entries.length
    end

    test "orders due entries oldest first and honours the limit" do
      3.times do |index|
        record(subject_ref: "subject-#{index}", completed_at: Time.utc(2026, 1, 1 + index, 0, 0, 0))
      end

      report = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1)).call(limit: 2)

      assert_equal 2, report.entries.length
      assert_equal report.entries.map(&:due_at).sort, report.entries.map(&:due_at)
      assert_predicate report, :truncated
      refute_predicate report, :complete?
    end

    test "clamps an out-of-range limit instead of scanning unbounded" do
      report = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1)).call(limit: 0)
      assert_equal 1, report.limit

      high = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1)).call(limit: 10_000_000)
      assert_equal DueForErasure::MAX_LIMIT, high.limit

      bad = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1)).call(limit: "not-a-number")
      assert_equal DueForErasure::DEFAULT_LIMIT, bad.limit
    end

    test "reports evidence it cannot date instead of silently dropping it" do
      record(subject_ref: "subject-user", completed_at: Time.utc(2026, 1, 1))
      record(subject_ref: "subject-note", completed_at: Time.utc(2026, 1, 1), model: "Note")

      # The registry declares User only, so the Note receipt cannot be dated.
      report = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1)).call

      assert_equal 1, report.entries.length
      assert_equal 1, report.undatable.length
      undatable = report.undatable.first
      assert_equal "Note", undatable.model
      assert_equal SubjectToken.derive(secret: SECRET, subject_ref: "subject-note"), undatable.subject_token
      assert_match(/no declaration/i, undatable.reason)
      refute_predicate report, :complete?
    end

    test "reports a row that bypassed the store as unverifiable and never as due" do
      receipt = insert_unverifiable(subject_ref: "subject-tampered")

      report = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1)).call

      assert_empty report.entries
      assert_equal 1, report.unverifiable.length
      assert_equal receipt.subject_token, report.unverifiable.first.subject_token
      assert_match(/verify/i, report.unverifiable.first.reason)
      refute_predicate report, :complete?
    end

    test "the append-only trigger still blocks rewriting a receipt" do
      receipt = record(subject_ref: "subject-stable", completed_at: Time.utc(2026, 1, 1))
      connection = ActiveRecord::Base.connection

      connection.execute("SAVEPOINT tamper_probe")
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("UPDATE erasure_receipts SET actions = '[]'::jsonb WHERE id = #{receipt.id}")
      end
      connection.execute("ROLLBACK TO SAVEPOINT tamper_probe")
      connection.execute("RELEASE SAVEPOINT tamper_probe")

      assert ErasureReceipt.find(receipt.id).verified?(SECRET)
    end

    test "an intact row queried with the wrong secret is unverifiable, not due" do
      record(subject_ref: "subject-secret", completed_at: Time.utc(2026, 1, 1))

      report = DueForErasure.new(registry: registry, secret: "wrong-secret", now: Time.utc(2026, 6, 1)).call

      assert_empty report.entries
      assert_equal 1, report.unverifiable.length
      refute_predicate report, :complete?
    end

    test "requires a secret and fails closed at construction" do
      assert_raises(DueForErasure::ConfigurationError) do
        DueForErasure.new(registry: registry, secret: "")
      end
      assert_raises(DueForErasure::ConfigurationError) do
        DueForErasure.new(registry: registry, secret: nil)
      end
    end

    test "a changed declaration changes the due answer without rewriting evidence" do
      record(subject_ref: "subject-shift", completed_at: Time.utc(2026, 1, 1))
      now = Time.utc(2026, 2, 15)

      short = DueForErasure.new(registry: registry(retention: "30 days"), secret: SECRET, now: now).call
      long = DueForErasure.new(registry: registry(retention: "2 years"), secret: SECRET, now: now).call

      assert_equal 1, short.entries.length
      assert_empty long.entries
      # The longer declaration only moves the due date; the evidence is intact
      # and is still datable, so neither report is inconclusive.
      assert_empty long.undatable
      assert_empty long.unverifiable
      assert_predicate long, :complete?
      assert_equal 1, ErasureReceipt.count
      assert ErasureReceipt.first.verified?(SECRET)
    end

    test "filters to a single subject token" do
      one = record(subject_ref: "subject-one", completed_at: Time.utc(2026, 1, 1))
      record(subject_ref: "subject-two", completed_at: Time.utc(2026, 1, 2))

      report = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1)).call(subject_token: one.subject_token)

      assert_equal [ one.subject_token ], report.entries.map(&:subject_token)
    end

    test "an empty evidence table is a complete, empty report" do
      report = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1)).call

      assert_empty report.entries
      assert_empty report.undatable
      assert_empty report.unverifiable
      assert_predicate report, :complete?
      assert_equal 0, report.due_count
    end

    test "due? answers per receipt using the same rules as the report" do
      due = record(subject_ref: "subject-a", completed_at: Time.utc(2026, 1, 1))
      # 30 days after 2026-05-20 is 2026-06-19, after the query instant.
      future = record(subject_ref: "subject-b", completed_at: Time.utc(2026, 5, 20))
      query = DueForErasure.new(registry: registry, secret: SECRET, now: Time.utc(2026, 6, 1))

      assert query.due?(due)
      refute query.due?(future)
      refute DueForErasure.new(registry: registry, secret: "wrong-secret", now: Time.utc(2026, 6, 1)).due?(due)
      refute DueForErasure.new(registry: Registry.new([]), secret: SECRET, now: Time.utc(2026, 6, 1)).due?(due)
    end
  end
end
