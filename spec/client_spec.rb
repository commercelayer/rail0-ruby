RSpec.describe Rail0::Client do
  let(:client) { Rail0::Client.new(base_url: BASE_URL) }

  def stub_get(path, body, status: 200)
    stub_request(:get, "#{BASE_URL}#{path}")
      .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_post(path, body, status: 202)
    stub_request(:post, "#{BASE_URL}#{path}")
      .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # ================================================================
  #  payments.get
  # ================================================================

  describe "payments.get" do
    it "returns payment state" do
      stub_get("/payments/#{PAYMENT_ID}", PAYMENT_RESPONSE)

      result = client.payments.get(PAYMENT_ID)

      expect(result[:paymentId]).to eq(PAYMENT_ID)
      expect(result[:state][:exists]).to be(true)
      expect(result[:state][:capturableAmount]).to eq("50000000")
    end
  end

  # ================================================================
  #  payments.authorize
  # ================================================================

  describe "payments.authorize" do
    it "returns a transaction response" do
      stub_post("/payments/#{PAYMENT_ID}/authorize", TX_RESPONSE)

      result = client.payments.authorize(PAYMENT_ID, {
        payment: PAYMENT,
        amount:  "50000000",
        v:       27,
        r:       "0x" + "11" * 32,
        s:       "0x" + "22" * 32
      })

      expect(result[:status]).to eq("pending")
      expect(result[:transactionHash]).to eq(TX_RESPONSE[:transactionHash])
    end
  end

  # ================================================================
  #  payments.charge
  # ================================================================

  describe "payments.charge" do
    it "returns a transaction response" do
      stub_post("/payments/#{PAYMENT_ID}/charge", TX_RESPONSE)

      result = client.payments.charge(PAYMENT_ID, {
        payment: PAYMENT, amount: "25000000",
        v: 27, r: "0x" + "11" * 32, s: "0x" + "22" * 32
      })

      expect(result[:status]).to eq("pending")
    end
  end

  # ================================================================
  #  payments.capture
  # ================================================================

  describe "payments.capture" do
    it "returns a transaction response" do
      stub_post("/payments/#{PAYMENT_ID}/capture", TX_RESPONSE)

      result = client.payments.capture(PAYMENT_ID, { payment: PAYMENT, amount: "50000000" })

      expect(result[:transactionHash]).to eq(TX_RESPONSE[:transactionHash])
    end
  end

  # ================================================================
  #  payments.void / release / refund
  # ================================================================

  describe "payments.void" do
    it "returns a transaction response" do
      stub_post("/payments/#{PAYMENT_ID}/void", TX_RESPONSE)
      result = client.payments.void(PAYMENT_ID, { payment: PAYMENT })
      expect(result[:status]).to eq("pending")
    end
  end

  describe "payments.release" do
    it "returns a transaction response" do
      stub_post("/payments/#{PAYMENT_ID}/release", TX_RESPONSE)
      result = client.payments.release(PAYMENT_ID, { payment: PAYMENT })
      expect(result[:status]).to eq("pending")
    end
  end

  describe "payments.refund" do
    it "returns a transaction response" do
      stub_post("/payments/#{PAYMENT_ID}/refund", TX_RESPONSE)
      result = client.payments.refund(PAYMENT_ID, { payment: PAYMENT, amount: "10000000" })
      expect(result[:status]).to eq("pending")
    end
  end

  # ================================================================
  #  payments.authorize_nonce / charge_nonce
  # ================================================================

  describe "payments.authorize_nonce" do
    it "returns a nonce" do
      nonce = "0xaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd"
      payer = PAYMENT[:payer]
      stub_get("/payments/#{PAYMENT_ID}/authorize-nonce?payer=#{payer}", { nonce: })

      result = client.payments.authorize_nonce(PAYMENT_ID, payer)

      expect(result[:nonce]).to eq(nonce)
    end
  end

  describe "payments.charge_nonce" do
    it "returns a nonce" do
      nonce = "0xaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd"
      payer = PAYMENT[:payer]
      stub_get("/payments/#{PAYMENT_ID}/charge-nonce?payer=#{payer}", { nonce: })

      result = client.payments.charge_nonce(PAYMENT_ID, payer)

      expect(result[:nonce]).to eq(nonce)
    end
  end

  # ================================================================
  #  payments.hash
  # ================================================================

  describe "payments.hash" do
    it "returns a config hash" do
      config_hash = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      stub_post("/payments/hash", { hash: config_hash }, status: 200)

      result = client.payments.hash(PAYMENT)

      expect(result[:hash]).to eq(config_hash)
    end
  end

  # ================================================================
  #  tokens.is_accepted
  # ================================================================

  describe "tokens.is_accepted" do
    it "returns token status" do
      address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
      stub_get("/tokens/#{address}", { address:, accepted: true })

      result = client.tokens.is_accepted(address)

      expect(result[:accepted]).to be(true)
    end
  end

  # ================================================================
  #  utils.domain_separator / version
  # ================================================================

  describe "utils.domain_separator" do
    it "returns the domain separator" do
      ds = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
      stub_get("/domain-separator", { domainSeparator: ds })

      result = client.utils.domain_separator

      expect(result[:domainSeparator]).to eq(ds)
    end
  end

  describe "utils.version" do
    it "returns the contract version" do
      stub_get("/version", { version: 6 })

      result = client.utils.version

      expect(result[:version]).to eq(6)
    end
  end

  # ================================================================
  #  Error handling
  # ================================================================

  describe "error handling" do
    it "raises Rail0::ApiError on 404" do
      stub_get("/payments/#{PAYMENT_ID}",
               { error: "PaymentNotFound", message: "No payment exists for the given paymentId." },
               status: 404)

      expect { client.payments.get(PAYMENT_ID) }
        .to raise_error(Rail0::ApiError) do |err|
          expect(err.status).to eq(404)
          expect(err.error).to eq("PaymentNotFound")
          expect(err.message).to include("No payment exists")
        end
    end

    it "raises Rail0::ApiError on 409" do
      stub_post("/payments/#{PAYMENT_ID}/authorize",
                { error: "PaymentAlreadyExists", message: "Payment already exists." },
                status: 409)

      expect do
        client.payments.authorize(PAYMENT_ID, {
          payment: PAYMENT, amount: "50000000",
          v: 27, r: "0x" + "11" * 32, s: "0x" + "22" * 32
        })
      end.to raise_error(Rail0::ApiError) do |err|
        expect(err.status).to eq(409)
        expect(err.error).to eq("PaymentAlreadyExists")
      end
    end

    it "raises Rail0::ApiError on 422" do
      stub_post("/payments/#{PAYMENT_ID}/capture",
                { error: "AuthorizationExpired", message: "The authorizationExpiry timestamp has passed." },
                status: 422)

      expect do
        client.payments.capture(PAYMENT_ID, { payment: PAYMENT, amount: "50000000" })
      end.to raise_error(Rail0::ApiError) do |err|
        expect(err.status).to eq(422)
        expect(err.error).to eq("AuthorizationExpired")
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
               { error: "PaymentNotFound", message: "Not found." },
               status: 404)

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
        { status: 404, body: { error: "PaymentNotFound", message: "Not found." }.to_json,
          headers: { "Content-Type" => "application/json" } }
      end

      retrying_client = Rail0::Client.new(base_url: BASE_URL, max_retries: 2, retry_delay: 0)

      expect { retrying_client.payments.get(PAYMENT_ID) }.to raise_error(Rail0::ApiError)
      expect(attempts).to eq(1)
    end
  end
end
