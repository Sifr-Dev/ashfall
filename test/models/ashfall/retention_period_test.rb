# frozen_string_literal: true

require "test_helper"

module Ashfall
  class RetentionPeriodTest < ActiveSupport::TestCase
    test "parses bounded duration units" do
      assert_equal 86_400, RetentionPeriod.parse("1 day").seconds
      assert_equal 1_209_600, RetentionPeriod.parse("2 weeks").seconds
      assert_equal 31_536_000, RetentionPeriod.parse("1 year").seconds
    end

    test "rejects ambiguous, zero, and excessive durations" do
      %w[forever "30" "1 month 2 days" "0 days" "101 years" "-1 day"].each do |value|
        assert_raises(Ashfall::Registry::InvalidDeclaration) { RetentionPeriod.parse(value) }
      end
    end

    test "a plan exposes a UTC due date when requested" do
      registry = Ashfall::Registry.new([
        { model: "User", column: "email", category: :contact, action: :delete, retention: "30 days", justification: nil }
      ])
      plan = registry.plan(subject: "subject-1", as_of: Time.utc(2026, 1, 1, 12))
      assert_equal "2026-01-31T12:00:00Z", plan.first[:due_at]
      assert plan.frozen?
      assert plan.first.frozen?
    end
  end
end
