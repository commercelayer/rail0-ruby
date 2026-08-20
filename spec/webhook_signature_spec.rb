# frozen_string_literal: true

require "spec_helper"

# Cross-checked against the gateway's own scheme:
#   Webhook#sign  → OpenSSL::HMAC.hexdigest("SHA256", shared_secret, "#{timestamp}.#{body}")
#   headers       → X-Rail0-Timestamp, X-Rail0-Signature  (commercelayer/rail0-gateway#176)
RSpec.describe Rail0::WebhookSignature do
  let(:secret)    { "whsec_0123456789abcdef" }
  let(:body)      { '{"topic":"payments.captured","payment_id":"0xabc"}' }
  let(:now)       { Time.at(1_770_000_000) }
  let(:timestamp) { now.to_i.to_s }
  let(:signature) { described_class.expected_signature(body, timestamp, secret) }

  def verify(**overrides)
    described_class.verify(body: body, signature: signature, timestamp: timestamp,
                           secret: secret, now: now, **overrides)
  end

  it "matches the gateway's HMAC over \"{timestamp}.{body}\"" do
    expect(signature).to eq(OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}"))
    expect(verify).to be(true)
  end

  it "rejects a tampered body" do
    expect(verify(body: body.sub("0xabc", "0xdef"))).to be(false)
  end

  it "rejects a signature made with another secret" do
    other = described_class.expected_signature(body, timestamp, "whsec_someone_elses")
    expect(verify(signature: other)).to be(false)
  end

  # The timestamp is part of the signed string, so re-signing under a different one
  # produces a different digest — this is what stops a captured delivery from being
  # replayable under a fresh timestamp.
  it "rejects a signature computed for a different timestamp" do
    expect(verify(signature: described_class.expected_signature(body, "1770000001", secret))).to be(false)
  end

  describe "the replay window" do
    it "accepts a delivery inside the tolerance, in either direction" do
      expect(verify(timestamp: (now.to_i - 299).to_s,
                    signature: described_class.expected_signature(body, (now.to_i - 299).to_s, secret))).to be(true)
      # A consumer whose clock runs slow sees a timestamp in the future; symmetric
      # tolerance keeps that from rejecting live deliveries.
      expect(verify(timestamp: (now.to_i + 299).to_s,
                    signature: described_class.expected_signature(body, (now.to_i + 299).to_s, secret))).to be(true)
    end

    # A VALID digest with a stale timestamp is exactly the replay case, so this must
    # fail — verifying the digest and ignoring the clock leaves the window open.
    it "rejects a correctly-signed but stale delivery" do
      stale = (now.to_i - 301).to_s
      expect(verify(timestamp: stale,
                    signature: described_class.expected_signature(body, stale, secret))).to be(false)
    end

    it "honours a custom tolerance" do
      old = (now.to_i - 3600).to_s
      sig = described_class.expected_signature(body, old, secret)
      expect(verify(timestamp: old, signature: sig)).to be(false)
      expect(verify(timestamp: old, signature: sig, tolerance: 7200)).to be(true)
    end
  end

  describe "malformed input" do
    it "returns false rather than raising" do
      expect(verify(timestamp: nil)).to be(false)
      expect(verify(timestamp: "not-a-number")).to be(false)
      expect(verify(signature: nil)).to be(false)
      expect(verify(signature: "")).to be(false)
      expect(verify(body: nil)).to be(false)
      expect(verify(secret: "")).to be(false)
      # A truncated signature must not pass on a prefix match.
      expect(verify(signature: signature[0, 32])).to be(false)
    end
  end
end
