RSpec.describe Rail0::Client do
  let(:client) { Rail0::Client.new(base_url: BASE_URL) }

  def stub_get(path, body, status: 200)
    stub_request(:get, "#{BASE_URL}#{path}")
      .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_post(path, body, status: 200)
    stub_request(:post, "#{BASE_URL}#{path}")
      .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_put(path, body, status: 200)
    stub_request(:put, "#{BASE_URL}#{path}")
      .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # ================================================================
  #  payments.create — POST /payments
  # ================================================================

  describe "payments.create" do
    it "returns a payment intent with signingPayload" do
      response = {
        paymentId:      PAYMENT_ID,
        configHash:     "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        payment:        PAYMENT_INPUT.merge(authorizationExpiry: 9_999_999_999, refundExpiry: 9_999_999_999, feeBps: 0, feeReceiver: "0x0000000000000000000000000000000000000000"),
        chainId:        84532,
        rail0Contract:  "0xRail0Contract0000000000000000000000000000",
        signingPayload: { domain: {}, types: {}, primaryType: "TransferWithAuthorization", message: {} }
      }
      stub_post("/payments", response, status: 201)

      result = client.payments.create(payment: PAYMENT_INPUT, chainId: 84532, mode: "authorize")

      expect(result[:paymentId]).to eq(PAYMENT_ID)
      expect(result[:signingPayload]).to be_a(Hash)
    end
  end

  # ================================================================
  #  payments.get — GET /payments/{id}
  # ================================================================

  describe "payments.get" do
    it "returns current payment state" do
      stub_get("/payments/#{PAYMENT_ID}", PAYMENT_RESPONSE)

      result = client.payments.get(PAYMENT_ID)

      expect(result[:paymentId]).to eq(PAYMENT_ID)
      expect(result[:status]).to eq("authorized")
      expect(result[:onChain][:exists]).to be(true)
      expect(result[:onChain][:capturableAmount]).to eq("100000000")
    end
  end

  # ================================================================
  #  payments.sign — PUT /payments/{id}/sign
  # ================================================================

  describe "payments.sign" do
    it "stores the payer signature and returns recoveredPayer" do
      stub_put("/payments/#{PAYMENT_ID}/sign", SIGN_RESPONSE)

      result = client.payments.sign(PAYMENT_ID, {
        signature: "0x" + "ab" * 65
      })

      expect(result[:status]).to eq("signature_stored")
      expect(result[:recoveredPayer]).to eq(PAYMENT_INPUT[:payer])
    end
  end

  # ================================================================
  #  payments.authorize_payload — POST /payments/{id}/authorize/payload
  # ================================================================

  describe "payments.authorize_payload" do
    it "returns an unsigned transaction" do
      stub_post("/payments/#{PAYMENT_ID}/authorize/payload", PREPARE_RESPONSE)

      result = client.payments.authorize_payload(PAYMENT_ID)

      expect(result[:unsignedTransaction]).to eq(PREPARE_RESPONSE[:unsignedTransaction])
      expect(result[:gasLimit]).to eq("200000")
    end
  end

  # ================================================================
  #  payments.authorize — POST /payments/{id}/authorize
  # ================================================================

  describe "payments.authorize" do
    it "returns 202 with status submitting" do
      stub_post("/payments/#{PAYMENT_ID}/authorize", SUBMIT_RESPONSE, status: 202)

      result = client.payments.authorize(PAYMENT_ID, { signedTransaction: "0x02f8ab1234" })

      expect(result[:paymentId]).to eq(PAYMENT_ID)
      expect(result[:status]).to eq("submitting")
    end
  end

  # ================================================================
  #  payments.charge_payload — POST /payments/{id}/charge/payload
  # ================================================================

  describe "payments.charge_payload" do
    it "returns an unsigned charge transaction" do
      stub_post("/payments/#{PAYMENT_ID}/charge/payload", PREPARE_RESPONSE)

      result = client.payments.charge_payload(PAYMENT_ID)

      expect(result[:unsignedTransaction]).to eq(PREPARE_RESPONSE[:unsignedTransaction])
    end
  end

  # ================================================================
  #  payments.capture_payload — POST /payments/{id}/capture/payload
  # ================================================================

  describe "payments.capture_payload" do
    it "returns an unsigned capture transaction" do
      stub_post("/payments/#{PAYMENT_ID}/capture/payload", PREPARE_RESPONSE)

      result = client.payments.capture_payload(PAYMENT_ID, { amount: "100000000" })

      expect(result[:chainId]).to eq(84532)
    end
  end

  # ================================================================
  #  payments.void_payload — POST /payments/{id}/void/payload
  # ================================================================

  describe "payments.void_payload" do
    it "returns an unsigned void transaction" do
      stub_post("/payments/#{PAYMENT_ID}/void/payload", PREPARE_RESPONSE)

      result = client.payments.void_payload(PAYMENT_ID)

      expect(result[:nonce]).to eq(42)
    end
  end

  # ================================================================
  #  payments.release_payload — POST /payments/{id}/release/payload
  # ================================================================

  describe "payments.release_payload" do
    it "returns an unsigned release transaction" do
      stub_post("/payments/#{PAYMENT_ID}/release/payload", PREPARE_RESPONSE)

      result = client.payments.release_payload(PAYMENT_ID)

      expect(result[:to]).to eq(PREPARE_RESPONSE[:to])
    end

    it "accepts an optional callerAddress" do
      stub_post("/payments/#{PAYMENT_ID}/release/payload", PREPARE_RESPONSE)

      result = client.payments.release_payload(PAYMENT_ID, { callerAddress: PAYMENT_INPUT[:payer] })

      expect(result[:unsignedTransaction]).to eq(PREPARE_RESPONSE[:unsignedTransaction])
    end
  end

  # ================================================================
  #  payments.refund_payload — POST /payments/{id}/refund/payload
  # ================================================================

  describe "payments.refund_payload" do
    it "returns signing_payload when called without v,r,s" do
      signing_resp = { signingPayload: { domain: {}, types: {}, primaryType: "ReceiveWithAuthorization", message: {} } }
      stub_post("/payments/#{PAYMENT_ID}/refund/payload", signing_resp)

      result = client.payments.refund_payload(PAYMENT_ID, { amount: "50000000" })

      expect(result[:signingPayload]).to be_a(Hash)
    end

    it "returns unsigned_transaction when called with v,r,s" do
      stub_post("/payments/#{PAYMENT_ID}/refund/payload", PREPARE_RESPONSE)

      result = client.payments.refund_payload(PAYMENT_ID, { amount: "50000000", v: 27, r: "0x" + "aa" * 32, s: "0x" + "bb" * 32 })

      expect(result[:gasLimit]).to eq("200000")
    end
  end

  # ================================================================
  #  payments.refund — POST /payments/{id}/refund
  # ================================================================

  describe "payments.refund" do
    it "returns 202 with status submitting" do
      stub_post("/payments/#{PAYMENT_ID}/refund", SUBMIT_RESPONSE, status: 202)

      result = client.payments.refund(PAYMENT_ID, { signedTransaction: "0x02f8ab1234" })

      expect(result[:status]).to eq("submitting")
    end
  end

  # ================================================================
  #  accounts.payment_methods — GET /accounts/{id}/payment-methods
  # ================================================================

  describe "accounts.payment_methods" do
    it "returns a list of accepted payment methods" do
      stub_get("/accounts/#{ACCOUNT_ID}/payment-methods", [PAYMENT_METHOD])

      result = client.accounts.payment_methods(ACCOUNT_ID)

      expect(result).to be_an(Array)
      expect(result.first[:tokenSymbol]).to eq("USDC")
      expect(result.first[:isDefault]).to be(true)
    end
  end

  # ================================================================
  #  Error handling
  # ================================================================

  describe "error handling" do
    it "raises Rail0::ApiError on 422 (payment not found)" do
      stub_get("/payments/#{PAYMENT_ID}",
               { error: "payment_not_found", message: "No payment exists for the given paymentId." },
               status: 422)

      expect { client.payments.get(PAYMENT_ID) }
        .to raise_error(Rail0::ApiError) do |err|
          expect(err.status).to eq(422)
          expect(err.error).to eq("payment_not_found")
          expect(err.message).to include("No payment exists")
        end
    end

    it "raises Rail0::ApiError on 400 (missing fields)" do
      stub_post("/payments/#{PAYMENT_ID}/capture/payload",
                { error: "missing_amount", message: "amount is required." },
                status: 400)

      expect { client.payments.capture_payload(PAYMENT_ID, {}) }
        .to raise_error(Rail0::ApiError) do |err|
          expect(err.status).to eq(400)
          expect(err.error).to eq("missing_amount")
        end
    end

    it "raises Rail0::ApiError on 422 (no pending operation)" do
      stub_post("/payments/#{PAYMENT_ID}/capture",
                { error: "no_pending_operation", message: "No prepare step was called yet." },
                status: 422)

      expect do
        client.payments.capture(PAYMENT_ID, { signedTransaction: "0x02f8ab" })
      end.to raise_error(Rail0::ApiError) do |err|
        expect(err.status).to eq(422)
        expect(err.error).to eq("no_pending_operation")
      end
    end
  end

  # ================================================================
  #  Logging
  # ================================================================

  describe "logging" do
    it "calls the logger with a LogEntry on success" do
      entries = []
      logged_client = Rail0::Client.new(base_url: BASE_URL, logger: ->(e) { entries << e })
      stub_get("/payments/#{PAYMENT_ID}", PAYMENT_RESPONSE)

      logged_client.payments.get(PAYMENT_ID)

      expect(entries.size).to eq(1)
      entry = entries.first
      expect(entry.method).to eq("GET")
      expect(entry.status).to eq(200)
      expect(entry.error).to be_nil
    end

    it "calls the logger with error on API failure" do
      entries = []
      logged_client = Rail0::Client.new(base_url: BASE_URL, logger: ->(e) { entries << e })
      stub_get("/payments/#{PAYMENT_ID}",
               { error: "payment_not_found", message: "Not found." },
               status: 422)

      expect { logged_client.payments.get(PAYMENT_ID) }.to raise_error(Rail0::ApiError)

      expect(entries.size).to eq(1)
      expect(entries.first.error).to be_a(Rail0::ApiError)
    end

    it "DEBUG_LOGGER writes to stdout" do
      stub_get("/payments/#{PAYMENT_ID}", PAYMENT_RESPONSE)
      logged_client = Rail0::Client.new(base_url: BASE_URL, logger: Rail0::DEBUG_LOGGER)

      expect { logged_client.payments.get(PAYMENT_ID) }.to output(/\[rail0\]/).to_stdout
    end
  end

  # ================================================================
  #  Retry
  # ================================================================

  describe "retry" do
    it "retries on network errors and succeeds" do
      attempt = 0
      stub_request(:get, "#{BASE_URL}/payments/#{PAYMENT_ID}").to_return do
        attempt += 1
        if attempt < 3
          raise SocketError, "connection refused"
        else
          { status: 200, body: PAYMENT_RESPONSE.to_json, headers: { "Content-Type" => "application/json" } }
        end
      end

      retrying_client = Rail0::Client.new(base_url: BASE_URL, max_retries: 2, retry_delay: 0)
      result = retrying_client.payments.get(PAYMENT_ID)

      expect(result[:paymentId]).to eq(PAYMENT_ID)
      expect(attempt).to eq(3)
    end

    it "does not retry HTTP errors" do
      attempts = 0
      stub_request(:get, "#{BASE_URL}/payments/#{PAYMENT_ID}").to_return do
        attempts += 1
        { status: 422, body: { error: "payment_not_found", message: "Not found." }.to_json,
          headers: { "Content-Type" => "application/json" } }
      end

      retrying_client = Rail0::Client.new(base_url: BASE_URL, max_retries: 2, retry_delay: 0)

      expect { retrying_client.payments.get(PAYMENT_ID) }.to raise_error(Rail0::ApiError)
      expect(attempts).to eq(1)
    end
  end
end
