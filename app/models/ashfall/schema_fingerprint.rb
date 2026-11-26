# frozen_string_literal: true

require "digest"

module Ashfall
  # Deterministic digest of the model columns and registry declarations that an
  # erasure plan was built from. Receipts record this value so a later reviewer
  # can tell whether the plan changed after the evidence was written.
  class SchemaFingerprint
    def initialize(registry:, model_classes:)
      @registry = registry
      @model_classes = model_classes
    end

    def to_s
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    private

    def payload
      declarations = @model_classes.flat_map do |klass|
        @registry.actions_for(klass.name).map { |d| [ d.model, d.column, d.action, d.retention ] }
      end
      [ @model_classes.map { |klass| [ klass.name, klass.column_names.sort ] }, declarations ]
    end
  end
end
