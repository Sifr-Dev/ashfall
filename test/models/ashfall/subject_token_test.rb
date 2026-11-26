# frozen_string_literal: true

require "test_helper"

module Ashfall
  class SubjectTokenTest < ActiveSupport::TestCase
    test "derives a token that does not contain the reference" do
      token = SubjectToken.derive(secret: "test-secret", subject_ref: "person@example.test")
      assert_match SubjectToken::FORMAT, token
      refute_includes token, "person"
      assert SubjectToken.valid?(token)
    end

    test "is deterministic for the same secret and reference" do
      first = SubjectToken.derive(secret: "test-secret", subject_ref: "subject-1")
      second = SubjectToken.derive(secret: "test-secret", subject_ref: "subject-1")
      assert_equal first, second
      refute_equal first, SubjectToken.derive(secret: "other-secret", subject_ref: "subject-1")
    end

    test "passes through only a well-formed token" do
      token = SubjectToken.derive(secret: "test-secret", subject_ref: "subject-1")
      assert_equal token, SubjectToken.derive(secret: "test-secret", subject_ref: token)
    end

    test "hashes a forged ashfall prefix instead of trusting it" do
      forged = "ashfall:forged"
      refute SubjectToken.valid?(forged)
      token = SubjectToken.derive(secret: "test-secret", subject_ref: forged)
      assert_match SubjectToken::FORMAT, token
      refute_equal forged, token
    end

    test "requires a secret" do
      assert_raises(ArgumentError) { SubjectToken.derive(secret: "", subject_ref: "subject-1") }
    end
  end
end
