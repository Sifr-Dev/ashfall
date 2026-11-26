# frozen_string_literal: true

require "openssl"
require "time"

module Ashfall
  class ErasureExecution
    class Error < StandardError; end
    class SubjectNotFound < Error; end
    class SchemaMismatch < Error; end
    class ConfigurationError < Error; end

    def initialize(registry:, model_classes:, secret:)
      raise ConfigurationError, "An erasure receipt secret is required" if secret.to_s.empty?
      @registry = registry
      @model_classes = model_classes
      @secret = secret
    end

    # Fail closed before any write: the target model must be loaded and every
    # column of the audited models must have a declaration.
    def validate!(model_name: "User", audit_models: nil)
      model_class = @model_classes.find { |klass| klass.name == model_name }
      raise SchemaMismatch, "#{model_name} model is not loaded" unless model_class
      audit = SchemaAudit.new(@registry, audit_models || [ model_class ])
      findings = audit.findings.select { |finding| finding.model == model_name }
      raise SchemaMismatch, findings.map(&:message).join("; ") if findings.any?

      model_class
    end

    # Applies the declared plan in one transaction and returns a frozen receipt.
    def call(subject_ref, model_name: "User", audit_models: nil)
      raise SubjectNotFound, "Subject reference is required" if subject_ref.blank?
      model_class = validate!(model_name: model_name, audit_models: audit_models)
      fingerprint = schema_fingerprint
      completed_at = Time.now.utc

      receipt = nil
      model_class.transaction do
        user = model_class.find_by!(subject_ref: subject_ref)
        receipt = {
          subject: subject_token(subject_ref),
          model_name: model_name,
          actions: apply_plan(user, subject_ref, model_name),
          completed_at: completed_at,
          schema_fingerprint: fingerprint
        }
      end
      receipt[:actions].each(&:freeze)
      receipt.freeze
    end

    def subject_token(subject_ref)
      SubjectToken.derive(secret: @secret, subject_ref: subject_ref)
    end

    def schema_fingerprint
      SchemaFingerprint.new(registry: @registry, model_classes: @model_classes).to_s
    end

    private

    def apply_plan(user, subject_ref, model_name = "User")
      @registry.actions_for(model_name).map do |declaration|
        case declaration.action
        when :delete
          user.update!(declaration.column => nil)
          { column: declaration.column, action: :deleted }
        when :pseudonymize
          value = declaration.column == "subject_ref" ? subject_token(subject_ref) : pseudonym(user, declaration.column)
          user.update!(declaration.column => value)
          { column: declaration.column, action: :pseudonymized }
        when :retain
          { column: declaration.column, action: :retained }
        end
      end
    end

    def pseudonym(user, column)
      "erased-#{OpenSSL::HMAC.hexdigest("SHA256", @secret, "user:#{user.id}:#{column}")}"
    end
  end
end
