# frozen_string_literal: true

module Ashfall
  class SchemaAudit
    Finding = Data.define(:kind, :model, :column, :message)
    ORDER = { unknown_model: 0, unknown_column: 1, undeclared_column: 2 }.freeze

    def initialize(registry, model_classes)
      @registry = registry
      @model_classes = model_classes.index_by(&:name)
    end

    def findings
      declared = @registry.plan(subject: "schema-audit")
      unknown_models = declared.reject { |d| @model_classes.key?(d[:model]) }
      findings = unknown_models.map do |d|
        Finding.new(:unknown_model, d[:model], d[:column], "Declared model is not loaded")
      end

      declared.reject { |d| unknown_models.include?(d) }.each do |d|
        klass = @model_classes.fetch(d[:model])
        columns = klass.column_names
        unless columns.include?(d[:column])
          findings << Finding.new(:unknown_column, d[:model], d[:column], "Declared column does not exist")
        end
      end
      @model_classes.each do |model, klass|
        (klass.column_names - declared_for_model(model).map { |item| item[:column] }).each do |column|
          findings << Finding.new(:undeclared_column, model, column, "Column has no erasure declaration")
        end
      end
      findings.sort_by { |f| [ ORDER.fetch(f.kind), f.model, f.column ].freeze }.freeze
    end

    private

    def declared_for_model(model)
      @registry.plan(subject: "schema-audit").select { |d| d[:model] == model }
    end
  end
end
