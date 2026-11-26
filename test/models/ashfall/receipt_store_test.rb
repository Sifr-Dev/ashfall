# frozen_string_literal: true

require "test_helper"

module Ashfall
  class ReceiptStoreTest < ActiveSupport::TestCase
    setup do
      @store = ReceiptStore.new(secret: "test-secret")
      @subject = SubjectToken.derive(secret: "test-secret", subject_ref: "subject-1")
      @fingerprint = "a" * 64
      @actions = [ { column: "email", action: "pseudonymized" }, { column: "name", action: "deleted" } ]
      @completed_at = Time.utc(2026, 1, 1, 12, 0, 0)
    end

    def record(**overrides)
      @store.record(
        subject_token: @subject,
        model: "User",
        schema_fingerprint: @fingerprint,
        actions: @actions,
        completed_at: @completed_at,
        **overrides
      )
    end

    test "persists a receipt with its digests and canonical action order" do
      receipt = record

      assert_predicate receipt, :persisted?
      assert_equal @subject, receipt.subject_token
      assert_equal "User", receipt.model
      assert_equal @fingerprint, receipt.schema_fingerprint
      assert_equal @completed_at, receipt.completed_at
      assert_match ErasureReceipt::HEX64, receipt.fingerprint
      assert_match ErasureReceipt::HEX64, receipt.signature
      assert_equal [ "email", "name" ], receipt.actions.map { |a| a["column"] }
      assert_predicate receipt, :readonly?
      assert receipt.verified?("test-secret")
    end

    test "a duplicate request returns the first receipt instead of writing a second row" do
      first = record
      second = record(completed_at: @completed_at + 60)

      assert_equal first.id, second.id
      assert_equal 1, ErasureReceipt.where(subject_token: @subject).count
      assert_equal first.completed_at, second.reload.completed_at
    end

    test "a retried request key cannot duplicate evidence for a changed plan" do
      record(idempotency_key: "request-key-0001")
      changed = [ { column: "email", action: "deleted" } ]

      assert_raises(ReceiptStore::PlanConflict) do
        record(idempotency_key: "request-key-0001", actions: changed)
      end
      assert_equal @actions.map { |a| { "column" => a[:column], "action" => a[:action] } }, ErasureReceipt.find_by!(idempotency_key: "request-key-0001").actions
      assert_equal 1, ErasureReceipt.count
    end

    test "a new plan for the same subject gets its own receipt" do
      first = record
      second = record(schema_fingerprint: "b" * 64)

      refute_equal first.id, second.id
      assert_equal 2, @store.receipts_for(@subject).length
    end

    test "rejects a raw subject reference instead of storing it" do
      assert_raises(ReceiptStore::InvalidReceipt) { record(subject_token: "person@example.test") }
      assert_equal 0, ErasureReceipt.count
    end

    test "rejects malformed fingerprints, models, keys, and actions" do
      assert_raises(ReceiptStore::InvalidReceipt) { record(schema_fingerprint: "nothex") }
      assert_raises(ReceiptStore::InvalidReceipt) { record(model: "user; DROP TABLE users") }
      assert_raises(ReceiptStore::InvalidReceipt) { record(idempotency_key: "short") }
      assert_raises(ReceiptStore::InvalidReceipt) { record(actions: [ { column: "email", action: "exported" } ]) }
      assert_equal 0, ErasureReceipt.count
    end

    test "a tampered row or the wrong secret does not verify" do
      receipt = record
      tampered = ErasureReceipt.new(receipt.attributes.except("id"))
      tampered.actions = [ { "column" => "email", "action" => "retained" } ]

      refute tampered.verified?("test-secret")
      refute receipt.verified?("wrong-secret")
      assert receipt.verified?("test-secret")
    end
  end
end
