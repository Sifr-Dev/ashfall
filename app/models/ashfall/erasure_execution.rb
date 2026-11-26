# frozen_string_literal: true

require "openssl"
require "digest"
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

    def call(subject_ref, model_name: "User", audit_models: nil)
      raise SubjectNotFound, "Subject reference is required" if subject_ref.blank?
      model_class = @model_classes.find { |klass| klass.name == model_name }
      raise SchemaMismatch, "#{model_name} model is not loaded" unless model_class
      audit = SchemaAudit.new(@registry, audit_models || [ model_class ])
      findings = audit.findings.select { |finding| finding.model == model_name }
      raise SchemaMismatch, findings.map(&:message).join("; ") if findings.any?

      receipt = nil
      model_class.transaction do
        user = model_class.find_by!(subject_ref: subject_ref)
        receipt = {
          subject: subject_token(subject_ref),
          actions: apply_plan(user, subject_ref, model_name),
          completed_at: Time.now.utc.iso8601,
          schema_fingerprint: schema_fingerprint(model_class)
        }
      end
      receipt[:actions].each(&:freeze)
      receipt.freeze
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

    def subject_token(subject_ref)
      return subject_ref if subject_ref.start_with?("ashfall:")
      "ashfall:#{OpenSSL::HMAC.hexdigest("SHA256", @secret, subject_ref)}"
    end

    def pseudonym(user, column)
      "erased-#{OpenSSL::HMAC.hexdigest("SHA256", @secret, "user:#{user.id}:#{column}")}"
    end

    def schema_fingerprint(model_class)
      declarations = @model_classes.flat_map do |klass|
        @registry.actions_for(klass.name).map { |d| [ d.model, d.column, d.action, d.retention ] }
      end
      Digest::SHA256.hexdigest([ @model_classes.map { |klass| [ klass.name, klass.column_names.sort ] }, declarations ].to_json)
    end
  end
end
