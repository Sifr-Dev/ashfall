# frozen_string_literal: true

require "time"

module Ashfall
  # Writes erasure receipts exactly once per erasure event.
  #
  # Two independent durable guards make duplicate handling safe:
  #
  # * the plan key (subject token, model name, schema fingerprint) is unique, so
  #   a repeated erasure request cannot add a second receipt for the same plan;
  # * the idempotency key is unique, so a retried request key cannot add a
  #   second receipt even when the plan changed between attempts.
  #
  # Every write is an INSERT ... ON CONFLICT DO NOTHING, and a conflict returns
  # the stored row instead of overwriting evidence. If the stored row disagrees
  # with the request, the store raises PlanConflict. The store never sees or
  # stores the original subject reference. It is an internal service object with
  # no HTTP endpoint; there is deliberately no route that can erase, read, or
  # delete receipts.
  class ReceiptStore
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class InvalidReceipt < Error; end
    class PlanConflict < Error; end

    PLAN_KEY_INDEX = "index_erasure_receipts_on_plan_key"
    IDEMPOTENCY_INDEX = "index_erasure_receipts_on_idempotency_key"
    ACTIONS = %w[deleted pseudonymized retained].freeze

    def initialize(secret:)
      raise ConfigurationError, "A receipt secret is required" if secret.to_s.empty?
      @secret = secret
    end

    # `idempotency_key` defaults to a digest of the plan itself. Callers that
    # retry a request may pass their own stable request key instead; the plan
    # key still prevents a second receipt for the same plan.
    def record(subject_token:, model_name:, schema_fingerprint:, actions:, completed_at:, idempotency_key: nil)
      idempotency_key ||= ErasureReceipt.plan_idempotency_key(
        subject_token: subject_token,
        model_name: model_name,
        schema_fingerprint: schema_fingerprint
      )
      payload = ErasureReceipt.canonical_payload(
        subject_token: subject_token,
        model_name: model_name,
        schema_fingerprint: schema_fingerprint,
        actions: actions,
        completed_at: completed_at
      )
      validate_payload!(payload, idempotency_key)

      attributes = {
        subject_token: payload["subject_token"],
        model_name: payload["model_name"],
        schema_fingerprint: payload["schema_fingerprint"],
        idempotency_key: idempotency_key,
        actions: payload["actions"],
        completed_at: completed_at,
        fingerprint: ErasureReceipt.fingerprint_for(payload),
        signature: ErasureReceipt.signature_for(payload, @secret),
        created_at: Time.current,
        updated_at: Time.current
      }

      receipt = insert_or_find_by_plan(attributes)
      ensure_same_evidence!(receipt, payload)
      receipt
    end

    def find(subject_token:, model_name:, schema_fingerprint:)
      ErasureReceipt.find_by(
        subject_token: subject_token,
        model_name: model_name,
        schema_fingerprint: schema_fingerprint
      )
    end

    def find_by_idempotency_key(idempotency_key)
      ErasureReceipt.find_by(idempotency_key: idempotency_key)
    end

    def receipts_for(subject_token)
      ErasureReceipt.for_subject(subject_token).to_a
    end

    private

    def insert_or_find_by_plan(attributes)
      inserted = ErasureReceipt.insert_all([ attributes ], returning: %w[id], unique_by: PLAN_KEY_INDEX)
      return ErasureReceipt.find(inserted.first.fetch("id")) if inserted.any?

      ErasureReceipt.find_by!(
        subject_token: attributes[:subject_token],
        model_name: attributes[:model_name],
        schema_fingerprint: attributes[:schema_fingerprint]
      )
    rescue ActiveRecord::RecordNotUnique
      # The idempotency key collided with a row for a different plan. Re-read it
      # so the caller gets a PlanConflict instead of a raw driver error.
      ErasureReceipt.find_by!(idempotency_key: attributes[:idempotency_key])
    end

    def ensure_same_evidence!(receipt, payload)
      same = receipt.actions == payload["actions"] &&
        receipt.subject_token == payload["subject_token"] &&
        receipt.model_name == payload["model_name"] &&
        receipt.schema_fingerprint == payload["schema_fingerprint"]
      raise PlanConflict, "Existing receipt disagrees with the retried erasure plan" unless same
    end

    def validate_payload!(payload, idempotency_key)
      unless SubjectToken.valid?(payload["subject_token"])
        raise InvalidReceipt, "Subject token must be an ashfall HMAC token"
      end
      unless payload["model_name"].match?(ErasureReceipt::MODEL_NAME)
        raise InvalidReceipt, "Model name is not a loaded model name"
      end
      unless payload["schema_fingerprint"].match?(ErasureReceipt::HEX64)
        raise InvalidReceipt, "Schema fingerprint must be a SHA-256 hex digest"
      end
      unless idempotency_key.is_a?(String) && idempotency_key.match?(ErasureReceipt::IDEMPOTENCY_KEY)
        raise InvalidReceipt, "Idempotency key must be 8-128 URL-safe characters"
      end
      unless payload["completed_at"].match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/)
        raise InvalidReceipt, "Completion time must be a microsecond UTC timestamp"
      end
      return if payload["actions"].all? { |action| action["action"].in?(ACTIONS) }

      raise InvalidReceipt, "Unknown erasure action in receipt"
    end
  end
end
