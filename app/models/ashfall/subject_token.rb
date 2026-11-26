# frozen_string_literal: true

require "openssl"

module Ashfall
  # The single identifier Ashfall keeps for an erased person.
  #
  # A token is an HMAC over the original subject reference, so the reference
  # cannot be recovered from it. Only a value that already matches the token
  # format is passed through unchanged; any other string is always hashed, so a
  # caller cannot smuggle a chosen "ashfall:" string into the receipts table.
  module SubjectToken
    FORMAT = /\Aashfall:[0-9a-f]{64}\z/

    def self.derive(secret:, subject_ref:)
      raise ArgumentError, "A receipt secret is required" if secret.to_s.empty?
      return subject_ref if valid?(subject_ref)

      "ashfall:#{OpenSSL::HMAC.hexdigest("SHA256", secret, subject_ref.to_s)}"
    end

    def self.valid?(value)
      value.is_a?(String) && value.match?(FORMAT)
    end
  end
end
