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

  # An older gateway sends neither code nor detail: the specific condition arrives in
  # `error` and the text in `message`. Both must still surface.
  it "falls back to the pre-code/title/detail field names" do
    stub_error(422, { status: "invalid_state", error: "not_capturable", message: "no capturable balance" })

    error = begin
      client.payments.get("0xabc")
    rescue Rail0::ApiError => e
      e
    end

    expect(error.error).to eq("not_capturable")
    expect(error.detail).to eq("no capturable balance")
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
  end
end
