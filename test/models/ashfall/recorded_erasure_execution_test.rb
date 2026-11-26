# frozen_string_literal: true

require "test_helper"

module Ashfall
  class RecordedErasureExecutionTest < ActiveSupport::TestCase
    test "forwards a caller's stable idempotency key to the stored receipt" do
      receipt = Struct.new(:subject, :model, :schema_fingerprint, :actions, :completed_at).new(
        "ashfall:#{'a' * 64}", "User", "b" * 64,
        [ { column: "email", action: :pseudonymized } ], Time.utc(2026, 1, 1)
      )
      execution = Object.new
      execution.define_singleton_method(:subject_token) { |_ref| receipt.subject }
      execution.define_singleton_method(:schema_fingerprint) { receipt.schema_fingerprint }
      execution.define_singleton_method(:call) { |_ref, model:| receipt }
      recorded = RecordedErasureExecution.new(
        execution: execution,
        store: ReceiptStore.new(secret: "test-secret")
      ).call("person@example.test", idempotency_key: "request-key-0001")

      assert_equal "request-key-0001", recorded.idempotency_key
      assert recorded.verified?("test-secret")
    end
  end
end
