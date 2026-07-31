# frozen_string_literal: true

require "openssl"

module Rail0
  # Verification for the signature the gateway puts on every webhook delivery.
  #
  # The SDK used to hand out `shared_secret` on create/rotate, tell the reader to
  # verify deliveries with it, and provide nothing to verify with — so every
  # consumer had to reverse-engineer the scheme, and getting it wrong is a security
  # bug in THEIR app, not a failed request. (#9)
  #
  # A delivery carries:
  #
  #   X-Rail0-Topic      the topic, e.g. "payments.captured"
  #   X-Rail0-Timestamp  unix seconds, as a string
  #   X-Rail0-Signature  hex HMAC-SHA256 over "{timestamp}.{body}", keyed by the secret
  #
  # The timestamp is inside the signed string on purpose: without it a captured
  # delivery is replayable forever, because the body alone stays valid indefinitely.
  # That is why {verify} rejects a stale timestamp even when the digest matches —
  # checking the digest and ignoring the clock leaves the replay window wide open.
  module WebhookSignature
    # Same window the gateway's own /sync channel uses, symmetric so a consumer
    # whose clock runs fast doesn't reject live deliveries.
    DEFAULT_TOLERANCE_SECONDS = 300

    class << self
      # Verify a delivery. Returns true / false — nothing here raises on a bad
      # signature, since a spoofed request is an expected condition on a public
      # endpoint, not an exception.
      #
      # @param body [String] the RAW request body, exactly as received. Re-serialising
      #   a parsed hash changes key order and whitespace, and the digest with it.
      # @param signature [String] the X-Rail0-Signature header.
      # @param timestamp [String, Integer] the X-Rail0-Timestamp header.
      # @param secret [String] the webhook's shared_secret.
      # @param tolerance [Integer] accepted clock skew in seconds, either direction.
      # @param now [Time] injectable clock, for tests.
      # @return [Boolean]
      def verify(body:, signature:, timestamp:, secret:, tolerance: DEFAULT_TOLERANCE_SECONDS, now: Time.now)
        return false if body.nil? || secret.to_s.empty?
        return false unless fresh?(timestamp, tolerance, now)

        secure_equal?(signature.to_s, expected_signature(body, timestamp, secret))
      end

      # The signature the gateway would send for this (timestamp, body). Exposed so a
      # consumer can log or diff the two sides when a delivery is being rejected —
      # comparing digests by eye is otherwise the only way to debug it.
      #
      # @return [String] hex HMAC-SHA256 over "{timestamp}.{body}"
      def expected_signature(body, timestamp, secret)
        OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
      end

      private

      def fresh?(timestamp, tolerance, now)
        seconds = Integer(timestamp.to_s, 10)
        (now.to_i - seconds).abs <= tolerance
      rescue ArgumentError, TypeError
        # A missing or non-numeric timestamp can't be inside any window.
        false
      end

      # Constant-time compare: a byte-by-byte early return leaks how much of the
      # digest matched, which is enough to forge one byte at a time.
      # OpenSSL.secure_compare needs equal lengths to be meaningful, and returns
      # false rather than raising on a mismatch, so the length check is explicit.
      def secure_equal?(given, expected)
        return false unless given.bytesize == expected.bytesize

        OpenSSL.secure_compare(given, expected)
      end
    end
  end
end
