RSpec.describe Rail0::Client do
  let(:client) { Rail0::Client.new(base_url: BASE_URL) }

  def json_headers
    { "Content-Type" => "application/json" }
  end

  def stub_get(path, body, status: 200)
    stub_request(:get, "#{BASE_URL}#{path}")
      .to_return(status: status, body: body.to_json, headers: json_headers)
  end

  # A paginated collection endpoint: bare JSON array body + pagination headers.
  def stub_list(path, items, total: nil, page: 1, per_page: 25)
    total ||= items.size
    stub_request(:get, "#{BASE_URL}#{path}")
      .to_return(status: 200, body: items.to_json, headers: json_headers.merge(
        "X-Total-Count" => total.to_s, "X-Page" => page.to_s, "X-Per-Page" => per_page.to_s
      ))
  end

  def stub_post(path, body, status: 200)
    stub_request(:post, "#{BASE_URL}#{path}")
      .to_return(status: status, body: body.to_json, headers: json_headers)
  end

  def stub_put(path, body, status: 200)
    stub_request(:put, "#{BASE_URL}#{path}")
      .to_return(status: status, body: body.to_json, headers: json_headers)
  end

  def stub_patch(path, body, status: 200)
    stub_request(:patch, "#{BASE_URL}#{path}")
      .to_return(status: status, body: body.to_json, headers: json_headers)
  end

  # ── Health ─────────────────────────────────────────────────────────────────

  describe "health.get" do
    it "returns the gateway health payload" do
      stub_get("/health", HEALTH)
      result = client.health.get
      expect(result[:status]).to eq("ok")
      expect(result[:api_version]).to eq("v1")
      expect(result[:contract_version]).to eq("1.2.1")
    end
  end

  # ── Chains ───────────────────────────────────────────────────────────────

  describe "chains.list" do
    it "returns the blockchain catalog" do
      stub_get("/blockchains", [BLOCKCHAIN])
      result = client.chains.list
      expect(result.first[:chain_id]).to eq(84532)
      expect(result.first[:native_symbol]).to eq("ETH")
    end

    it "passes network_type and symbol filters" do
      stub = stub_get("/blockchains?network_type=testnet&symbol=ETH", [BLOCKCHAIN])
      client.chains.list(network_type: "testnet", symbol: "ETH")
      expect(stub).to have_been_requested
    end
  end

  # ── Tokens ───────────────────────────────────────────────────────────────

  describe "tokens.list" do
    it "returns all tokens when no chain is given" do
      stub_get("/tokens", [TOKEN_INFO])
      result = client.tokens.list
      expect(result.first[:symbol]).to eq("USDC")
    end

    it "filters by chain_id and symbol" do
      stub = stub_get("/tokens?chain_id=84532&symbol=USDC", [TOKEN_INFO])
      client.tokens.list(chain_id: 84532, symbol: "USDC")
      expect(stub).to have_been_requested
    end

    it "treats chain_id 0 as all chains" do
      stub = stub_get("/tokens", [TOKEN_INFO])
      client.tokens.list(chain_id: 0)
      expect(stub).to have_been_requested
    end
  end

  # ── Payment methods (public) ─────────────────────────────────────────────

  describe "payment_methods.list" do
    it "lists a merchant's wallets by account_id" do
      stub_get("/payment_methods?account_id=#{ACCOUNT_ID}", [WALLET_WITH_TOKENS])
      result = client.payment_methods.list(account_id: ACCOUNT_ID)
      expect(result).to be_an(Array)
      expect(result.first[:tokens].first[:token][:symbol]).to eq("USDC")
    end

    it "lists a single wallet by address" do
      stub = stub_get("/payment_methods?address=#{PAYEE}", [WALLET_WITH_TOKENS])
      client.payment_methods.list(address: PAYEE)
      expect(stub).to have_been_requested
    end
  end

  # ── Auth (SIWE) ────────────────────────────────────────────────────────────

  describe "auth.nonce" do
    it "POSTs /auth/nonces and returns the nonce" do
      stub = stub_post("/auth/nonces", NONCE_RESPONSE, status: 201)
      result = client.auth.nonce
      expect(stub).to have_been_requested
      expect(result[:nonce]).to eq("tEsTn0nce42")
    end
  end

  describe "auth.verify" do
    it "POSTs message + signature to /auth and returns a session" do
      stub = stub_request(:post, "#{BASE_URL}/auth")
        .with(body: hash_including("message" => anything, "signature" => anything))
        .to_return(status: 201, body: SESSION_RESPONSE.to_json, headers: json_headers)
      result = client.auth.verify(message: "msg", signature: "0xdeadbeef")
      expect(stub).to have_been_requested
      expect(result[:token]).to eq("signed.jwt.token")
      expect(result[:account_id]).to eq(ACCOUNT_ID)
      expect(result[:name]).to eq("Merchant")
    end
  end

  describe "auth.login" do
    let(:key) { "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" }

    it "runs the full SIWE flow and produces a 65-byte signature" do
      stub_post("/auth/nonces", NONCE_RESPONSE, status: 201)
      captured = nil
      stub_request(:post, "#{BASE_URL}/auth").to_return do |req|
        captured = JSON.parse(req.body)
        { status: 201, body: SESSION_RESPONSE.to_json, headers: json_headers }
      end

      result = client.auth.login(private_key: key, domain: "api.rail0.xyz")

      expect(result[:token]).to eq("signed.jwt.token")
      expect(captured).to have_key("message")
      expect(captured["signature"]).to match(/\A0x[0-9a-fA-F]{130}\z/)
      expect(captured["message"]).to include("Chain ID: 1") # default login chain
    end

    it "embeds a custom chain_id in the SIWE message when given" do
      stub_post("/auth/nonces", NONCE_RESPONSE, status: 201)
      captured = nil
      stub_request(:post, "#{BASE_URL}/auth").to_return do |req|
        captured = JSON.parse(req.body)
        { status: 201, body: SESSION_RESPONSE.to_json, headers: json_headers }
      end

      client.auth.login(private_key: key, domain: "localhost", chain_id: 5042002)

      expect(captured["message"]).to include("Chain ID: 5042002")
    end

    it "raises Rail0::ApiError when the address is not registered" do
      stub_post("/auth/nonces", NONCE_RESPONSE, status: 201)
      stub_post("/auth", { status: "address_not_registered", message: "Address is not registered." }, status: 403)

      expect { client.auth.login(private_key: key, domain: "api.rail0.xyz") }
        .to raise_error(Rail0::ApiError) do |err|
          expect(err.status).to eq(403)
          expect(err.error).to eq("address_not_registered")
        end
    end
  end

  # ── Wallets (account-scoped, JWT) ────────────────────────────────────────

  describe "wallets" do
    let(:base) { "/accounts/#{ACCOUNT_ID}/wallets" }

    it "list returns a paginated envelope with meta from headers" do
      stub_list(base, [WALLET_WITH_TOKENS], total: 1, page: 1, per_page: 25)
      result = client.wallets.list(ACCOUNT_ID)
      expect(result[:data].first[:address]).to eq(PAYEE)
      expect(result[:meta]).to eq(page: 1, per_page: 25, total: 1)
    end

    it "list forwards filters" do
      stub = stub_list("#{base}?chain_id=84532&token_symbol=USDC&active=true", [WALLET_WITH_TOKENS])
      client.wallets.list(ACCOUNT_ID, chain_id: 84532, token_symbol: "USDC", active: true)
      expect(stub).to have_been_requested
    end

    it "get fetches a single wallet by id or address" do
      stub_get("#{base}/#{WALLET_ID}", WALLET)
      expect(client.wallets.get(ACCOUNT_ID, WALLET_ID)[:id]).to eq(WALLET_ID)
    end

    it "create posts address and label" do
      stub = stub_request(:post, "#{BASE_URL}#{base}")
        .with(body: { address: PAYEE, label: "Merchant wallet" })
        .to_return(status: 201, body: WALLET.to_json, headers: json_headers)
      client.wallets.create(ACCOUNT_ID, address: PAYEE, label: "Merchant wallet")
      expect(stub).to have_been_requested
    end

    it "update sends a real PATCH (not POST)" do
      stub = stub_patch("#{base}/#{WALLET_ID}", WALLET.merge(label: "Renamed"))
      result = client.wallets.update(ACCOUNT_ID, WALLET_ID, label: "Renamed")
      expect(stub).to have_been_requested
      expect(result[:label]).to eq("Renamed")
    end

    it "delete returns nil on 204 (empty body)" do
      stub_request(:delete, "#{BASE_URL}#{base}/#{WALLET_ID}").to_return(status: 204, body: "")
      expect(client.wallets.delete(ACCOUNT_ID, WALLET_ID)).to be_nil
    end

    it "balances returns live on-chain balances" do
      stub_get("#{base}/#{WALLET_ID}/balances", WALLET_BALANCES)
      result = client.wallets.balances(ACCOUNT_ID, WALLET_ID)
      expect(result[:balances].first[:tokens].first[:symbol]).to eq("USDC")
    end
  end

  # ── Payments: core ───────────────────────────────────────────────────────

  describe "payments.create" do
    it "returns an unsigned payment with a signing_payload" do
      stub_post("/payments", PAYMENT_UNSIGNED, status: 201)
      result = client.payments.create(
        chain_id: 84532, mode: "authorize", amount: "100000000",
        token: TOKEN, payer: PAYER, payee: PAYEE
      )
      expect(result[:rail0_id]).to eq(PAYMENT_ID)
      expect(result[:status]).to eq("unsigned")
      expect(result[:signing_payload]).to be_a(Hash)
    end

    it "sends the Idempotency-Key header when given" do
      stub = stub_request(:post, "#{BASE_URL}/payments")
        .with(headers: { "Idempotency-Key" => "key-123" })
        .to_return(status: 201, body: PAYMENT_UNSIGNED.to_json, headers: json_headers)
      client.payments.create({ chain_id: 84532, mode: "charge", amount: "1", token: TOKEN, payer: PAYER, payee: PAYEE },
                             idempotency_key: "key-123")
      expect(stub).to have_been_requested
    end
  end

  describe "payments.get" do
    it "returns current state by rail0_id" do
      stub_get("/payments/#{PAYMENT_ID}", PAYMENT_DETAIL)
      result = client.payments.get(PAYMENT_ID)
      expect(result[:status]).to eq("authorized")
      expect(result[:capturable_amount]).to eq("100000000")
    end
  end

  describe "payments.list" do
    it "returns a paginated envelope and forwards filters" do
      stub = stub_list("/payments?status=authorized&disputed=false&chain_id=84532",
                       [PAYMENT_DETAIL], total: 1)
      result = client.payments.list(status: "authorized", disputed: false, chain_id: 84532)
      expect(stub).to have_been_requested
      expect(result[:meta][:total]).to eq(1)
    end
  end

  describe "payments.transactions" do
    it "lists transactions with filters" do
      stub_list("/payments/#{PAYMENT_ID}/transactions?operation=capture", [SUBMIT_RESPONSE])
      result = client.payments.transactions(PAYMENT_ID, operation: "capture")
      expect(result[:data].first[:operation]).to eq("authorize")
    end
  end

  describe "payments.sign" do
    it "PUTs the payer signature" do
      stub = stub_put("/payments/#{PAYMENT_ID}/sign", PAYMENT_DETAIL.merge(status: "signed"))
      result = client.payments.sign(PAYMENT_ID, { signature: "0x#{'ab' * 65}" })
      expect(stub).to have_been_requested
      expect(result[:status]).to eq("signed")
    end
  end

  describe "payments.disputes" do
    it "lists a payment's dispute history" do
      stub_list("/payments/#{PAYMENT_ID}/disputes?status=open", [DISPUTE])
      result = client.payments.disputes(PAYMENT_ID, status: "open")
      expect(result[:data].first[:status]).to eq("open")
    end
  end

  # ── Payments: lifecycle operations ─────────────────────────────────────────

  describe "lifecycle prepare/submit wrappers" do
    it "authorize_prepare returns an unsigned transaction" do
      stub_post("/payments/#{PAYMENT_ID}/authorize/prepare", PREPARE_RESPONSE, status: 201)
      result = client.payments.authorize_prepare(PAYMENT_ID)
      expect(result[:unsigned_transaction]).to eq(UNSIGNED_TX_JSON)
    end

    it "authorize submits the signed tx (202)" do
      stub_post("/payments/#{PAYMENT_ID}/authorize", SUBMIT_RESPONSE, status: 202)
      result = client.payments.authorize(PAYMENT_ID, { signed_transaction: "0x02f8ab" })
      expect(result[:status]).to eq("submitting")
    end

    it "charge_prepare / charge" do
      stub_post("/payments/#{PAYMENT_ID}/charge/prepare", PREPARE_RESPONSE, status: 201)
      stub_post("/payments/#{PAYMENT_ID}/charge", SUBMIT_RESPONSE, status: 202)
      expect(client.payments.charge_prepare(PAYMENT_ID)[:status]).to eq("pending")
      expect(client.payments.charge(PAYMENT_ID, { signed_transaction: "0x02" })[:status]).to eq("submitting")
    end

    it "capture_prepare sends the amount in the body" do
      stub = stub_request(:post, "#{BASE_URL}/payments/#{PAYMENT_ID}/capture/prepare")
        .with(body: { amount: "40000000" })
        .to_return(status: 201, body: PREPARE_RESPONSE.to_json, headers: json_headers)
      client.payments.capture_prepare(PAYMENT_ID, "40000000")
      expect(stub).to have_been_requested
    end

    it "void_prepare / void" do
      stub_post("/payments/#{PAYMENT_ID}/void/prepare", PREPARE_RESPONSE, status: 201)
      stub_post("/payments/#{PAYMENT_ID}/void", SUBMIT_RESPONSE, status: 202)
      expect(client.payments.void_prepare(PAYMENT_ID)[:operation]).to eq("authorize")
      expect(client.payments.void(PAYMENT_ID, { signed_transaction: "0x02" })[:status]).to eq("submitting")
    end

    it "release_prepare defaults to an empty body and accepts from" do
      empty = stub_request(:post, "#{BASE_URL}/payments/#{PAYMENT_ID}/release/prepare")
        .with(body: {}).to_return(status: 201, body: PREPARE_RESPONSE.to_json, headers: json_headers)
      client.payments.release_prepare(PAYMENT_ID)
      expect(empty).to have_been_requested

      with_from = stub_request(:post, "#{BASE_URL}/payments/#{PAYMENT_ID}/release/prepare")
        .with(body: { from: PAYER }).to_return(status: 201, body: PREPARE_RESPONSE.to_json, headers: json_headers)
      client.payments.release_prepare(PAYMENT_ID, from: PAYER)
      expect(with_from).to have_been_requested
    end

    it "refund_prepare phase-1 (amount only) returns a signing payload" do
      stub = stub_request(:post, "#{BASE_URL}/payments/#{PAYMENT_ID}/refund/prepare")
        .with(body: { amount: "50000000" })
        .to_return(status: 200, body: REFUND_SIGNING_RESPONSE.to_json, headers: json_headers)
      result = client.payments.refund_prepare(PAYMENT_ID, amount: "50000000")
      expect(stub).to have_been_requested
      expect(result[:signing_payload][:primaryType]).to eq("ReceiveWithAuthorization")
    end

    it "refund_prepare phase-2 (amount + signature) returns an unsigned tx" do
      stub = stub_request(:post, "#{BASE_URL}/payments/#{PAYMENT_ID}/refund/prepare")
        .with(body: { amount: "50000000", signature: "0x#{'cd' * 65}" })
        .to_return(status: 201, body: PREPARE_RESPONSE.to_json, headers: json_headers)
      client.payments.refund_prepare(PAYMENT_ID, amount: "50000000", signature: "0x#{'cd' * 65}")
      expect(stub).to have_been_requested
    end

    it "refund submits the signed tx" do
      stub_post("/payments/#{PAYMENT_ID}/refund", SUBMIT_RESPONSE, status: 202)
      expect(client.payments.refund(PAYMENT_ID, { signed_transaction: "0x02" })[:status]).to eq("submitting")
    end
  end

  describe "generic prepare/submit/submit_by_hash" do
    it "prepare posts to /{op}/prepare" do
      stub_post("/payments/#{PAYMENT_ID}/capture/prepare", PREPARE_RESPONSE, status: 201)
      expect(client.payments.prepare(PAYMENT_ID, "capture", { amount: "1" })[:status]).to eq("pending")
    end

    it "submit posts to /{op}" do
      stub_post("/payments/#{PAYMENT_ID}/capture", SUBMIT_RESPONSE, status: 202)
      expect(client.payments.submit(PAYMENT_ID, "capture", { signed_transaction: "0x02" })[:status]).to eq("submitting")
    end

    it "submit_by_hash posts the hash to /{op}/submitted" do
      stub = stub_request(:post, "#{BASE_URL}/payments/#{PAYMENT_ID}/capture/submitted")
        .with(body: { transaction_hash: "0x#{'ee' * 32}" })
        .to_return(status: 202, body: SUBMIT_RESPONSE.to_json, headers: json_headers)
      client.payments.submit_by_hash(PAYMENT_ID, "capture", { transaction_hash: "0x#{'ee' * 32}" })
      expect(stub).to have_been_requested
    end
  end

  # ── Payments: disputes (payer-driven) ──────────────────────────────────────

  describe "dispute operations" do
    it "dispute_prepare omits reason by default and includes it when given" do
      no_reason = stub_request(:post, "#{BASE_URL}/payments/#{PAYMENT_ID}/dispute/prepare")
        .with(body: {}).to_return(status: 201, body: PREPARE_RESPONSE.to_json, headers: json_headers)
      client.payments.dispute_prepare(PAYMENT_ID)
      expect(no_reason).to have_been_requested

      with_reason = stub_request(:post, "#{BASE_URL}/payments/#{PAYMENT_ID}/dispute/prepare")
        .with(body: { reason: "0x#{'0' * 64}" }).to_return(status: 201, body: PREPARE_RESPONSE.to_json, headers: json_headers)
      client.payments.dispute_prepare(PAYMENT_ID, reason: "0x#{'0' * 64}")
      expect(with_reason).to have_been_requested
    end

    it "dispute submits the signed tx" do
      stub_post("/payments/#{PAYMENT_ID}/dispute", SUBMIT_RESPONSE, status: 202)
      expect(client.payments.dispute(PAYMENT_ID, { signed_transaction: "0x02" })[:status]).to eq("submitting")
    end

    it "close_dispute_prepare / close_dispute hit the /dispute/close paths" do
      stub_post("/payments/#{PAYMENT_ID}/dispute/close/prepare", PREPARE_RESPONSE)
      stub_post("/payments/#{PAYMENT_ID}/dispute/close", SUBMIT_RESPONSE, status: 202)
      expect(client.payments.close_dispute_prepare(PAYMENT_ID)[:operation]).to eq("authorize")
      expect(client.payments.close_dispute(PAYMENT_ID, { signed_transaction: "0x02" })[:status]).to eq("submitting")
    end
  end

  # ── Webhooks (JWT) ─────────────────────────────────────────────────────────

  describe "webhooks" do
    it "list returns a paginated envelope" do
      stub_list("/webhooks?topic=payments.captured", [WEBHOOK])
      result = client.webhooks.list(topic: "payments.captured")
      expect(result[:data].first[:topic]).to eq("payments.captured")
    end

    it "create returns the one-time shared_secret" do
      stub = stub_request(:post, "#{BASE_URL}/webhooks")
        .with(body: { name: "orders", callback_url: "https://merchant.example/hook", topic: "payments.captured" })
        .to_return(status: 201, body: WEBHOOK_WITH_SECRET.to_json, headers: json_headers)
      result = client.webhooks.create(name: "orders", callback_url: "https://merchant.example/hook", topic: "payments.captured")
      expect(stub).to have_been_requested
      expect(result[:shared_secret]).to eq("whsec_test_abc123")
    end

    it "get / update / delete" do
      stub_get("/webhooks/#{WEBHOOK_ID}", WEBHOOK)
      expect(client.webhooks.get(WEBHOOK_ID)[:id]).to eq(WEBHOOK_ID)

      stub_patch("/webhooks/#{WEBHOOK_ID}", WEBHOOK.merge(name: "renamed"))
      expect(client.webhooks.update(WEBHOOK_ID, name: "renamed")[:name]).to eq("renamed")

      stub_request(:delete, "#{BASE_URL}/webhooks/#{WEBHOOK_ID}").to_return(status: 204, body: "")
      expect(client.webhooks.delete(WEBHOOK_ID)).to be_nil
    end

    it "enable / disable / reset_circuit are no-body PUTs returning the webhook" do
      %w[enable disable reset_circuit].each do |action|
        stub_put("/webhooks/#{WEBHOOK_ID}/#{action}", WEBHOOK)
      end
      expect(client.webhooks.enable(WEBHOOK_ID)[:id]).to eq(WEBHOOK_ID)
      expect(client.webhooks.disable(WEBHOOK_ID)[:id]).to eq(WEBHOOK_ID)
      expect(client.webhooks.reset_circuit(WEBHOOK_ID)[:id]).to eq(WEBHOOK_ID)
    end

    it "rotate_secret returns a fresh shared_secret" do
      stub_put("/webhooks/#{WEBHOOK_ID}/rotate_secret", WEBHOOK_WITH_SECRET)
      expect(client.webhooks.rotate_secret(WEBHOOK_ID)[:shared_secret]).to eq("whsec_test_abc123")
    end

    it "event_callbacks lists deliveries and maps until_time -> until" do
      stub = stub_list("/webhooks/#{WEBHOOK_ID}/event_callbacks?status=failed&until=2026-07-10T00:00:00Z",
                       [{ id: "cb1", status: "failed" }])
      client.webhooks.event_callbacks(WEBHOOK_ID, status: "failed", until_time: "2026-07-10T00:00:00Z")
      expect(stub).to have_been_requested
    end
  end

  # ── Error handling ─────────────────────────────────────────────────────────

  describe "error handling" do
    it "raises Rail0::ApiError on 422 with status/message" do
      stub_get("/payments/#{PAYMENT_ID}",
               { status: "payment_not_found", message: "No payment exists for the given id." }, status: 422)
      expect { client.payments.get(PAYMENT_ID) }
        .to raise_error(Rail0::ApiError) do |err|
          expect(err.status).to eq(422)
          expect(err.error).to eq("payment_not_found")
          expect(err.message).to include("No payment exists")
        end
    end

    it "raises Rail0::ApiError on a 422 state error" do
      stub_post("/payments/#{PAYMENT_ID}/capture",
                { status: "not_capturable", message: "Payment is not capturable." }, status: 422)
      expect { client.payments.capture(PAYMENT_ID, { signed_transaction: "0x02" }) }
        .to raise_error(Rail0::ApiError) { |err| expect(err.error).to eq("not_capturable") }
    end
  end

  # ── Logging ──────────────────────────────────────────────────────────────

  describe "logging" do
    it "calls the logger with a success LogEntry" do
      entries = []
      logged = Rail0::Client.new(base_url: BASE_URL, logger: ->(e) { entries << e })
      stub_get("/payments/#{PAYMENT_ID}", PAYMENT_DETAIL)
      logged.payments.get(PAYMENT_ID)
      expect(entries.size).to eq(1)
      expect(entries.first.method).to eq("GET")
      expect(entries.first.status).to eq(200)
    end

    it "DEBUG_LOGGER writes to stdout" do
      stub_get("/payments/#{PAYMENT_ID}", PAYMENT_DETAIL)
      logged = Rail0::Client.new(base_url: BASE_URL, logger: Rail0::DEBUG_LOGGER)
      expect { logged.payments.get(PAYMENT_ID) }.to output(/\[rail0\]/).to_stdout
    end
  end

  # ── Retry ──────────────────────────────────────────────────────────────────

  describe "retry" do
    it "retries network errors and succeeds" do
      attempt = 0
      stub_request(:get, "#{BASE_URL}/payments/#{PAYMENT_ID}").to_return do
        attempt += 1
        raise SocketError, "connection refused" if attempt < 3

        { status: 200, body: PAYMENT_DETAIL.to_json, headers: json_headers }
      end
      retrying = Rail0::Client.new(base_url: BASE_URL, max_retries: 2, retry_delay: 0)
      expect(retrying.payments.get(PAYMENT_ID)[:rail0_id]).to eq(PAYMENT_ID)
      expect(attempt).to eq(3)
    end

    it "does not retry HTTP errors" do
      attempts = 0
      stub_request(:get, "#{BASE_URL}/payments/#{PAYMENT_ID}").to_return do
        attempts += 1
        { status: 422, body: { status: "payment_not_found", message: "x" }.to_json, headers: json_headers }
      end
      retrying = Rail0::Client.new(base_url: BASE_URL, max_retries: 2, retry_delay: 0)
      expect { retrying.payments.get(PAYMENT_ID) }.to raise_error(Rail0::ApiError)
      expect(attempts).to eq(1)
    end
  end
end
