# frozen_string_literal: true

module Ashfall
  # Answers "which subjects are due for erasure now?" from stored evidence.
  #
  # This is a bounded administrative query, not a deletion workflow. It reports
  # the receipts whose longest declared retention has elapsed as of a supplied
  # UTC instant, and it refuses to hide evidence it cannot account for.
  #
  # Every stored receipt lands in exactly one of three buckets in the returned
  # Report:
  #
  # * `entries` — the receipt verifies against the secret and its model has a
  #   declaration, so a due date can be computed. Only these are "due" answers.
  # * `unverifiable` — the stored row does not match its own HMAC and
  #   fingerprint. A row edited by someone who bypassed the append-only
  #   triggers, or a query run with the wrong secret, fails verification here
  #   instead of being reported as ordinary due evidence.
  # * `undatable` — the receipt is intact but its model no longer has a
  #   declaration, so the current declaration set cannot say when it is due.
  #
  # Earlier versions dropped the last two categories with `next unless
  # retention`. That made undeclared or tampered evidence invisible, so an
  # operator saw "nothing due" when the honest answer was "I cannot tell".
  # `Report#complete?` is the fail-closed signal: it is false whenever any
  # evidence could not be verified or dated.
  #
  # The retention period is attached to the registry declaration, not to the
  # receipt, so a due date is always computed from the current declaration set.
  # A changed declaration therefore changes the answer; the receipt keeps the
  # fingerprint of the plan that actually ran so the two can be compared, but
  # this query does not itself decide whether a fingerprint drift is acceptable.
  #
  # There is intentionally no controller or route for this query. Callers are
  # trusted internal code, and the limit is clamped to a bounded range.
  class DueForErasure
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 1_000

    class Error < StandardError; end
    class ConfigurationError < Error; end

    Entry = Data.define(:subject_token, :model, :schema_fingerprint, :completed_at, :due_at, :retention)
    Undatable = Data.define(:subject_token, :model, :schema_fingerprint, :completed_at, :reason)
    Unverifiable = Data.define(:subject_token, :model, :schema_fingerprint, :completed_at, :reason)

    # `complete?` is false when any evidence was skipped, so a caller that only
    # wants a clean answer can require it and treat the query as inconclusive.
    Report = Data.define(:entries, :undatable, :unverifiable, :as_of, :limit, :truncated) do
      def complete?
        undatable.empty? && unverifiable.empty? && !truncated
      end

      def due_count
        entries.length
      end
    end

    def initialize(registry:, secret:, now: Time.now.utc)
      raise ConfigurationError, "A receipt secret is required" if secret.to_s.empty?

      @registry = registry
      @secret = secret
      @now = now
    end

    # Returns a Report. `limit` is clamped rather than raising, so a bad caller
    # cannot request an unbounded scan, and it bounds every bucket so a single
    # large category cannot dominate memory.
    def call(limit: DEFAULT_LIMIT, subject_token: nil)
      requested = bounded(limit)
      entries = []
      undatable = []
      unverifiable = []

      scope = ErasureReceipt.order(:completed_at, :id)
      scope = scope.where(subject_token: subject_token) if subject_token
      scope.find_each do |receipt|
        unless receipt.verified?(@secret)
          unverifiable << unverifiable_record(receipt)
          next
        end

        retention = retention_for(receipt)
        if retention.nil?
          undatable << undatable_record(receipt)
          next
        end

        due_at = receipt.completed_at + retention.seconds
        next if due_at > @now

        entries << Entry.new(
          subject_token: receipt.subject_token,
          model: receipt.model,
          schema_fingerprint: receipt.schema_fingerprint,
          completed_at: receipt.completed_at,
          due_at: due_at,
          retention: retention.text
        )
      end

      entries.sort_by! { |entry| [ entry.due_at, entry.subject_token, entry.model ] }

      Report.new(
        entries: entries.first(requested).freeze,
        undatable: undatable.first(requested).freeze,
        unverifiable: unverifiable.first(requested).freeze,
        as_of: @now,
        limit: requested,
        truncated: entries.length > requested || undatable.length > requested || unverifiable.length > requested
      )
    end

    # A single receipt is due only when it verifies and its model is declared,
    # so an inconclusive row never reads as a clean "not yet due" answer.
    def due?(receipt)
      return false unless receipt.verified?(@secret)

      retention = retention_for(receipt)
      return false if retention.nil?

      receipt.completed_at + retention.seconds <= @now
    end

    private

    def bounded(limit)
      requested = Integer(limit, exception: false) || DEFAULT_LIMIT
      requested.clamp(1, MAX_LIMIT)
    end

    def unverifiable_record(receipt)
      Unverifiable.new(
        subject_token: receipt.subject_token,
        model: receipt.model,
        schema_fingerprint: receipt.schema_fingerprint,
        completed_at: receipt.completed_at,
        reason: "Receipt does not verify against the configured secret"
      )
    end

    def undatable_record(receipt)
      Undatable.new(
        subject_token: receipt.subject_token,
        model: receipt.model,
        schema_fingerprint: receipt.schema_fingerprint,
        completed_at: receipt.completed_at,
        reason: "No declaration exists for #{receipt.model}, so no retention applies"
      )
    end

    def retention_for(receipt)
      declarations = @registry.actions_for(receipt.model)
      return nil if declarations.empty?

      # The receipt is evidence for the whole plan. The plan becomes due when
      # every declaration in it is due, i.e. when the longest retention ends.
      declarations.map { |d| RetentionPeriod.parse(d.retention) }.max_by(&:seconds)
    end
  end
end
