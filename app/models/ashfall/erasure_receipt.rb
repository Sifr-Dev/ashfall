# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "time"

module Ashfall
  # Durable, append-only evidence that a declared erasure plan completed.
  #
  # A receipt stores only the pseudonymous subject token, the canonical model
  # name, the plan's schema fingerprint, the action outcomes, and two digests
  # over that content. It never stores the original subject reference. The row
  # is written once: the model refuses persisted mutations, unique indexes reject
  # duplicates, and PostgreSQL triggers reject UPDATE and DELETE.
  #
  # This is a technical integrity control, not a legal certificate.
  class ErasureReceipt < ApplicationRecord
    self.table_name = "erasure_receipts"

    DOMAIN = "ashfall.erasure-receipt.v1"
    HEX64 = /\A[0-9a-f]{64}\z/
    MODEL_NAME = /\A[A-Z][A-Za-z0-9_:]*\z/
    IDEMPOTENCY_KEY = /\A[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\z/

    scope :for_subject, ->(subject_token) { where(subject_token: subject_token).order(completed_at: :asc, id: :asc) }
    scope :recent_first, -> { order(completed_at: :desc, id: :desc) }

    validates :subject_token, presence: true, format: { with: SubjectToken::FORMAT }
    validates :model_name, presence: true, format: { with: MODEL_NAME }
    validates :schema_fingerprint, presence: true, format: { with: HEX64 }
    validates :idempotency_key, presence: true, format: { with: IDEMPOTENCY_KEY }
    validates :fingerprint, presence: true, format: { with: HEX64 }
    validates :signature, presence: true, format: { with: HEX64 }
    validates :completed_at, presence: true
    validate :actions_are_an_array

    class << self
      def canonical_payload(subject_token:, model_name:, schema_fingerprint:, actions:, completed_at:)
        normalized_actions = Array(actions).map do |action|
          {
            "column" => (action[:column] || action["column"]).to_s,
            "action" => (action[:action] || action["action"]).to_s
          }
        end
        normalized_actions.sort_by! { |action| [ action["column"], action["action"] ] }

        {
          "domain" => DOMAIN,
          "subject_token" => subject_token.to_s,
          "model_name" => model_name.to_s,
          "schema_fingerprint" => schema_fingerprint.to_s,
          "actions" => normalized_actions,
          "completed_at" => completed_at.utc.iso8601(6)
        }
      end

      def fingerprint_for(payload)
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def signature_for(payload, secret)
        OpenSSL::HMAC.hexdigest("SHA256", secret, JSON.generate(payload))
      end

      # Default idempotency key for a plan: stable for the same subject token,
      # model, and schema fingerprint, so a retried request is recognized even
      # if no explicit request key was supplied.
      def plan_idempotency_key(subject_token:, model_name:, schema_fingerprint:)
        Digest::SHA256.hexdigest(JSON.generate([ DOMAIN, "plan", subject_token.to_s, model_name.to_s, schema_fingerprint.to_s ]))
      end
    end

    # Never let a loaded row be updated or destroyed through Active Record.
    def readonly?
      persisted?
    end

    def canonical_payload
      self.class.canonical_payload(
        subject_token: subject_token,
        model_name: model_name,
        schema_fingerprint: schema_fingerprint,
        actions: actions,
        completed_at: completed_at
      )
    end

    # Recompute both digests from the stored row. A row edited by someone who
    # can bypass the triggers fails this check even though the row still exists.
    def verified?(secret)
      raise ArgumentError, "A receipt secret is required" if secret.to_s.empty?

      expected_fingerprint = self.class.fingerprint_for(canonical_payload)
      expected_signature = self.class.signature_for(canonical_payload, secret)
      ActiveSupport::SecurityUtils.secure_compare(fingerprint, expected_fingerprint) &
        ActiveSupport::SecurityUtils.secure_compare(signature, expected_signature)
    end

    private

    def actions_are_an_array
      return if actions.is_a?(Array) && actions.all? { |a| a.is_a?(Hash) && a["column"].is_a?(String) && a["action"].is_a?(String) }

      errors.add(:actions, "must be an array of column/action pairs")
    end
  end
end
