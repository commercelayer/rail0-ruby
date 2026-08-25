# frozen_string_literal: true

RSpec.describe "error surface" do
  let(:client) { Rail0::Client.new(base_url: BASE_URL) }

  def stub_error(status, body)
    stub_request(:get, "#{BASE_URL}/payments/0xabc")
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # The gateway answers code/title/detail. `code` is the specific condition and
  # `status` the wider family it sits in, so reading `status` as the code — which this
  # SDK used to do — hands a caller "invalid_state" where the gateway said
  # "amount_exceeds_refundable", and hides exactly what went wrong.
  it "prefers code over the status family, and carries title and detail" do
    stub_error(422, {
                 code: "amount_exceeds_refundable",
                 title: "Amount above the refundable balance",
                 detail: "The amount is higher than the balance the merchant still holds for this payment.",
                 status: "invalid_state",
                 message: "The amount is higher than the balance the merchant still holds for this payment."
               })

    error = begin
      client.payments.get("0xabc")
    rescue Rail0::ApiError => e
      e
    end

    expect(error.error).to eq("amount_exceeds_refundable")
    expect(error.title).to eq("Amount above the refundable balance")
    expect(error.detail).to start_with("The amount is higher")
    expect(error.message).to eq(error.detail)
    expect(error.status).to eq(422)
  end

  # This used to assert the OPPOSITE: that an older gateway's `status`/`error`/`message`
  # still surfaced. Those keys were deleted from the wire rather than dual-sent (#252),
  # so what matters now is that a body carrying only them yields nothing pretending to be
  # a code — a silent "" would be branched on as if it were a real condition.
  it "does not invent a code from the deleted alias fields" do
    stub_error(422, { status: "invalid_state", error: "not_capturable", message: "no capturable balance" })

    error = begin
      client.payments.get("0xabc")
    rescue Rail0::ApiError => e
      e
    end

    expect(error.error).to be_nil
    expect(error.detail).to eq("HTTP 422")
    expect(error.title).to be_nil
  end

  it "falls back to the bare HTTP status when the body carries no text" do
    stub_error(500, { code: "db_error" })

    error = begin
      client.payments.get("0xabc")
    rescue Rail0::ApiError => e
      e
    end

    expect(error.error).to eq("db_error")
    expect(error.message).to eq("HTTP 500")
  end

  describe "hints" do
    # A supplement to the gateway's detail, not a replacement — so it exists only for
    # codes with a next step worth adding, and never invents one.
    it "returns an actionable hint for a known code" do
      expect(Rail0.describe_error("insufficient_gas_funds")).to include("native token")
      expect(Rail0.describe_error("not_the_payee")).to include("merchant")
    end

    it "returns nil for an unknown or empty code" do
      expect(Rail0.describe_error("brand_new_condition")).to be_nil
      expect(Rail0.describe_error(nil)).to be_nil
      expect(Rail0.describe_error("")).to be_nil
    end

    it "exposes the same hint through the raised error" do
      stub_error(422, { code: "authorization_already_used", detail: "spent" })

      error = begin
        client.payments.get("0xabc")
      rescue Rail0::ApiError => e
        e
      end

      expect(error.hint).to eq(Rail0.describe_error("authorization_already_used"))
      expect(error.hint).to include("single-use")
    end

    # The three SDKs and the CLI share this table; a code the gateway can return with no
    # entry here is not a bug, but the families that DO have entries must stay complete —
    # these are the ones a user hits most and cannot diagnose from the code alone.
    it "covers the token-level and broadcast families" do
      %w[insufficient_token_balance invalid_token_signature authorization_already_used
         insufficient_gas_funds nonce_too_low replacement_underpriced already_known
         config_hash_mismatch unsupported_contract_version].each do |code|
        expect(Rail0.describe_error(code)).not_to be_nil, "#{code} has no hint"
      end
    end

    # The five that rail0-go carried and this table did not. Kept as an explicit list
    # rather than a count, so the next divergence names the missing code (#13).
    it "covers the codes rail0-go had drifted ahead on" do
      %w[unsupported_payment_method unknown_token no_active_contract
         missing_param forbidden].each do |code|
        expect(Rail0.describe_error(code)).not_to be_nil, "#{code} has no hint"
      end
    end

    # `forbidden` is the one whose hint has to say something the code cannot: the
    # payer/caller rule on create is the most common way to hit it.
    it "explains what forbidden usually means on create" do
      expect(Rail0.describe_error("forbidden")).to include("payer")
    end
  end
end

RSpec.describe "rate limiting" do
  BASE = BASE_URL

  def throttled(retry_after: "60")
    headers = { "Content-Type" => "application/json" }
    headers["Retry-After"] = retry_after if retry_after
    {
      status: 429,
      body: { code: "rate_limited", title: "Too many requests",
              detail: "Rate limit reached. Retry in 60 seconds." }.to_json,
      headers: headers
    }
  end

  describe "the error a 429 raises" do
    it "carries retry_after, so a caller is not left guessing" do
      # The SDK used to drop the header: "rate limited" arrived with no idea for how long.
      stub_request(:get, "#{BASE}/health").to_return(throttled)
      client = Rail0::Client.new(base_url: BASE)

      expect { client.health.get }.to raise_error(Rail0::ApiError) do |err|
        expect(err.status).to eq(429)
        expect(err.error).to eq("rate_limited")
        expect(err.retry_after).to eq(60)
      end
    end

    it "leaves retry_after nil when the header is absent or unusable" do
      ["0", "later", nil].each do |value|
        stub_request(:get, "#{BASE}/health").to_return(throttled(retry_after: value))
        client = Rail0::Client.new(base_url: BASE)
        expect { client.health.get }.to raise_error(Rail0::ApiError) { |e|
          expect(e.retry_after).to be_nil
        }
      end
    end

    it "is nil on every other error" do
      stub_request(:get, "#{BASE}/health")
        .to_return(status: 404, body: { code: "not_found" }.to_json,
                   headers: { "Content-Type" => "application/json" })
      client = Rail0::Client.new(base_url: BASE)
      expect { client.health.get }.to raise_error(Rail0::ApiError) { |e|
        expect(e.retry_after).to be_nil
      }
    end
  end

  describe "retry_on_429" do
    it "does not retry by default — the 429 is the caller's to handle" do
      stub = stub_request(:get, "#{BASE}/health").to_return(throttled)
      client = Rail0::Client.new(base_url: BASE)
      expect { client.health.get }.to raise_error(Rail0::ApiError)
      expect(stub).to have_been_requested.once
    end

    it "retries once on its own, without max_retries also being set" do
      # The pairing would be a footgun: the flag would silently do nothing.
      stub = stub_request(:get, "#{BASE}/health")
             .to_return(throttled)
             .then.to_return(status: 200, body: { status: "ok" }.to_json,
                             headers: { "Content-Type" => "application/json" })
      client = Rail0::Client.new(base_url: BASE, retry_on_429: true, retry_delay: 0,
                                 retry_after_cap: 0)
      expect(client.health.get[:status]).to eq("ok")
      expect(stub).to have_been_requested.twice
    end

    it "gives up after the budget and raises the last 429 with its retry_after" do
      stub_request(:get, "#{BASE}/health").to_return(throttled)
      client = Rail0::Client.new(base_url: BASE, retry_on_429: true, max_retries: 2,
                                 retry_delay: 0, retry_after_cap: 0)
      expect { client.health.get }.to raise_error(Rail0::ApiError) { |e|
        expect(e.retry_after).to eq(60)
      }
      expect(a_request(:get, "#{BASE}/health")).to have_been_made.times(3)
    end

    it "retries a POST as readily as a GET" do
      # Safe specifically because Rack::Attack rejects in middleware, before the request
      # reaches the application: nothing ran, so nothing can run twice. Not true of a 502.
      stub = stub_request(:post, "#{BASE}/auth/nonces")
             .to_return(throttled)
             .then.to_return(status: 201, body: { nonce: "abc" }.to_json,
                             headers: { "Content-Type" => "application/json" })
      client = Rail0::Client.new(base_url: BASE, retry_on_429: true, retry_delay: 0,
                                 retry_after_cap: 0)
      expect(client.auth.nonce[:nonce]).to eq("abc")
      expect(stub).to have_been_requested.twice
    end
  end
end
