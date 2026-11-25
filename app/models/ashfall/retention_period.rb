# frozen_string_literal: true

module Ashfall
  class RetentionPeriod
    UNITS = {
      "day" => 86_400,
      "days" => 86_400,
      "week" => 604_800,
      "weeks" => 604_800,
      "month" => 2_592_000,
      "months" => 2_592_000,
      "year" => 31_536_000,
      "years" => 31_536_000
    }.freeze

    attr_reader :seconds, :text

    def self.parse(value)
      text = value.to_s.strip
      match = /\A(\d+)\s+(day|days|week|weeks|month|months|year|years)\z/.match(text)
      raise Registry::InvalidDeclaration, "Unsupported retention period: #{value.inspect}" unless match
      amount = Integer(match[1], 10)
      raise Registry::InvalidDeclaration, "Retention period must be positive" if amount <= 0
      seconds = amount * UNITS.fetch(match[2])
      raise Registry::InvalidDeclaration, "Retention period is too large" if seconds > 100 * UNITS.fetch("year")
      new(seconds, text)
    end

    def initialize(seconds, text)
      @seconds = seconds
      @text = text.freeze
      freeze
    end

    def due_at(time)
      time + seconds
    end
  end
end
