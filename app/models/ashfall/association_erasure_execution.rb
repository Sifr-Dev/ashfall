# frozen_string_literal: true

module Ashfall
  class AssociationErasureExecution
    def initialize(registry:, model_classes:, secret:)
      @base = ErasureExecution.new(registry: registry, model_classes: model_classes, secret: secret)
      @registry = registry
      @model_classes = model_classes
      @secret = secret
    end

    def call(subject_ref)
      model_class = @model_classes.find { |klass| klass.name == "User" }
      raise ErasureExecution::SchemaMismatch, "User model is not loaded" unless model_class
      audit = SchemaAudit.new(@registry, @model_classes)
      findings = audit.findings
      raise ErasureExecution::SchemaMismatch, findings.map(&:message).join("; ") if findings.any?

      model_class.transaction do
        user = model_class.find_by!(subject_ref: subject_ref)
        note_class = @model_classes.find { |klass| klass.name == "Note" }
        if note_class
          user.notes.find_each do |note|
            apply_note_actions(note)
          end
        end
        @base.call(subject_ref, audit_models: [ model_class ])
      end
    end

    private

    def apply_note_actions(note)
      @registry.actions_for("Note").each do |declaration|
        case declaration.action
        when :delete
          note.update!(declaration.column => nil)
        when :pseudonymize
          note.update!(declaration.column => "erased-#{OpenSSL::HMAC.hexdigest("SHA256", @secret, "note:#{note.id}:#{declaration.column}")}")
        end
      end
    end
  end
end
