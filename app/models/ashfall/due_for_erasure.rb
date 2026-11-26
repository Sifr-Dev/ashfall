# frozen_string_literal: true

module Ashfall
  # Answers "which subjects are due for erasure now?" from stored evidence.
  #
  # This is a query, not a deletion workflow. It reports the receipts whose
  # longest declared retention has elapsed as of a caller-supplied UTC instant.
  # The retention period is attached to the registry declaration, not to the
  # receipt, so the due date is always computed from the current declaration
  # set; a changed declaration changes the answer and that is visible because
  # the receipt keeps the fingerprint of the plan that actually ran.
  #
  # There is intentionally no controller or route for this query. Callers are
  # trusted internal code, and the default limit is bounded.
  class DueForErasure
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 1_000

    Entry = Data.define(:subject_token, :model_name, :schema_fingerprint, :completed_at, :due_at, :retention)

    def initialize(registry:, now: Time.now.utc)
      @registry = registry
      @now = now
    end

    # Returns entries ordered by due date, oldest first. `limit` is clamped to a
    # bounded range instead of raising so a bad caller cannot request an
    # unbounded scan.
    def call(limit: DEFAULT_LIMIT, subject_token: nil)
      entries = []
      scope = ErasureReceipt.order(:completed_at, :id)
      scope = scope.where(subject_token: subject_token) if subject_token
      scope.find_each do |receipt|
        retention = retention_for(receipt)
        next unless retention

        due_at = receipt.completed_at + retention.seconds
        next if due_at > @now

        entries << Entry.new(
          subject_token: receipt.subject_token,
          model_name: receipt.model_name,
          schema_fingerprint: receipt.schema_fingerprint,
          completed_at: receipt.completed_at,
          due_at: due_at,
          retention: retention.text
        )
      end
      entries.sort_by { |entry| [ entry.due_at, entry.subject_token, entry.model_name ] }.first(bounded(limit))
    end

    def due?(receipt)
      retention = retention_for(receipt)
      retention && receipt.completed_at + retention.seconds <= @now
    end

    private

    def bounded(limit)
      requested = Integer(limit, exception: false) || DEFAULT_LIMIT
      requested.clamp(1, MAX_LIMIT)
    end

    def retention_for(receipt)
      declarations = @registry.actions_for(receipt.model_name)
      return nil if declarations.empty?

      # The receipt is evidence for the whole plan. The plan becomes due when
      # every declaration in it is due, i.e. when the longest retention ends.
      declarations.map { |d| RetentionPeriod.parse(d.retention) }.max_by(&:seconds)
    end
  end
end
