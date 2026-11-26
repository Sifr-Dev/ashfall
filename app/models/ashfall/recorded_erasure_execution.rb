# frozen_string_literal: true

module Ashfall
  # Runs an erasure plan and records its receipt in the same transaction.
  #
  # The receipt write shares the erasure transaction, so if evidence cannot be
  # written the erasure itself is rolled back. A plan that already has a receipt
  # returns it without re-applying actions. Concurrent first-time callers both
  # apply the same deterministic plan; the database keeps exactly one receipt.
  class RecordedErasureExecution
    class Error < StandardError; end

    def initialize(execution:, store:)
      @execution = execution
      @store = store
    end

    # Returns the persisted Ashfall::ErasureReceipt. The caller can check
    # receipt.verified?(secret) and receipt.actions without trusting this call.
    def call(subject_ref, model: "User", idempotency_key: nil)
      raise ErasureExecution::SubjectNotFound, "Subject reference is required" if subject_ref.blank?

      subject_token = @execution.subject_token(subject_ref)
      schema_fingerprint = @execution.schema_fingerprint

      existing = @store.find(subject_token: subject_token, model: model, schema_fingerprint: schema_fingerprint)
      return existing if existing

      recorded = nil
      ActiveRecord::Base.transaction do
        receipt = @execution.call(subject_ref, model: model)
        recorded = @store.record(
          subject_token: receipt[:subject],
          model: receipt[:model],
          schema_fingerprint: receipt[:schema_fingerprint],
          actions: receipt[:actions],
          completed_at: receipt[:completed_at],
          idempotency_key: idempotency_key
        )
      end
      recorded || raise(Error, "Erasure completed without recording a receipt")
    end
  end
end
