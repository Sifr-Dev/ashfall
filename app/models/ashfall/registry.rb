require "yaml"

module Ashfall
  class Registry
    Category = Data.define(:model, :column, :category, :action, :retention, :justification)
    ACTIONS = %i[delete pseudonymize retain].freeze

    class Error < StandardError; end
    class InvalidDeclaration < Error; end
    class RetentionJustificationRequired < Error; end

    def initialize(declarations)
      @declarations = declarations.map { |d| Category.new(**d) }
      validate!
      @periods = @declarations.to_h { |d| [ [ d.model, d.column ], RetentionPeriod.parse(d.retention) ] }
    end

    def self.from_yaml(path)
      raw = YAML.safe_load_file(path, permitted_classes: [ Symbol ], aliases: false)
      new(raw.fetch("declarations").map do |entry|
        declaration = entry.transform_keys(&:to_sym)
        declaration[:category] = declaration[:category].to_sym if declaration[:category].is_a?(String)
        declaration[:action] = declaration[:action].to_sym if declaration[:action].is_a?(String)
        declaration
      end)
    end

    def actions_for(model)
      @declarations.select { |d| d.model == model }
    end

    def plan(subject:, as_of: nil)
      @declarations.map do |declaration|
        {
          model: declaration.model,
          column: declaration.column,
          category: declaration.category,
          action: declaration.action,
          subject: subject,
          retention: declaration.retention,
          due_at: as_of && @periods.fetch([ declaration.model, declaration.column ]).due_at(as_of).utc.iso8601,
          justification: declaration.justification
        }.freeze
      end.freeze
    end

    private

    def validate!
      @declarations.each do |d|
        unless d.model.is_a?(String) && d.model.match?(/\A[A-Z][A-Za-z0-9_:]*\z/)
          raise InvalidDeclaration, "Invalid model name: #{d.model.inspect}"
        end
        unless d.column.is_a?(String) && d.column.match?(/\A[a-z_][a-z0-9_]*\z/)
          raise InvalidDeclaration, "Invalid column name: #{d.column.inspect}"
        end
        unless d.category.is_a?(Symbol) && d.category.match?(/\A[a-z_][a-z0-9_]*\z/)
          raise InvalidDeclaration, "Invalid category: #{d.category.inspect}"
        end
        unless ACTIONS.include?(d.action)
          raise InvalidDeclaration, "Unknown erasure action: #{d.action.inspect}"
        end
        if d.retention.nil? || !d.retention.is_a?(String) || d.retention.empty?
          raise InvalidDeclaration, "A retention period is required for #{d.model}.#{d.column}"
        end
        if d.action == :retain && (d.justification.nil? || d.justification.strip.empty?)
          raise RetentionJustificationRequired, "Retention of #{d.model}.#{d.column} requires a justification"
        end
      end
    end
  end
end
