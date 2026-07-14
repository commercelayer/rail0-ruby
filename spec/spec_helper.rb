require "webmock/rspec"
require "rail0"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.warnings = true
  config.order = :random
end

# ── Shared test fixtures ─────────────────────────────────────────────────────
# All shapes mirror the current gateway entities (flat, snake_case).

BASE_URL   = "https://api.rail0.xyz"
PAYMENT_ID = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" # rail0_id
PAYMENT_UUID = "018e1234-5678-7abc-9def-0123456789ab"
ACCOUNT_ID = "018e1234-5678-7abc-9def-012345678901"
WALLET_ID  = "018e2222-3333-7abc-9def-012345678902"
WEBHOOK_ID = "018e3333-4444-7abc-9def-012345678903"

PAYER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
PAYEE = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
TOKEN = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" # Base USDC

# Payment::Unsigned — create response while still unsigned (embeds signing_payload).
PAYMENT_UNSIGNED = {
  id:            PAYMENT_UUID,
  rail0_id:      PAYMENT_ID,
  status:        "unsigned",
  mode:          "authorize",
  amount:        "100000000",
  payer:         PAYER,
  payee:         PAYEE,
  token:         TOKEN,
  chain_id:      84532,
  disputed:      false,
  signing_payload: {
    domain:      { name: "USD Coin", version: "2", chainId: 84532, verifyingContract: TOKEN },
    primaryType: "TransferWithAuthorization",
    message:     { from: PAYER, to: TOKEN, value: "100000000", validAfter: "0", validBefore: "9999999999",
                   nonce: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab" }
  }
}.freeze

# Payment::Detail — a signed/authorized payment with live balances + transactions.
PAYMENT_DETAIL = {
  id:               PAYMENT_UUID,
  rail0_id:         PAYMENT_ID,
  status:           "authorized",
  mode:             "authorize",
  amount:           "100000000",
  capturable_amount: "100000000",
  refundable_amount: "0",
  payer:            PAYER,
  payee:            PAYEE,
  token:            TOKEN,
  chain_id:         84532,
  disputed:         false,
  transactions:     []
}.freeze

# Transaction::Restricted returned by a prepare step. unsigned_transaction is the
# EIP-1559 tx field-set as a JSON string (the client signs it locally).
UNSIGNED_TX_JSON = {
  chain_id: 84532, nonce: 7, to: "0x1111111111111111111111111111111111111111",
  value: "0", data: "0xa9059cbb",
  gas_limit: 210_000, max_priority_fee_per_gas: "1000000000", max_fee_per_gas: "2500000000"
}.to_json

PREPARE_RESPONSE = {
  id:                  "018e5555-6666-7abc-9def-012345678905",
  payment_id:          PAYMENT_UUID,
  operation:           "authorize",
  status:              "pending",
  unsigned_transaction: UNSIGNED_TX_JSON
}.freeze

# Transaction::Restricted returned by a submit step (HTTP 202).
SUBMIT_RESPONSE = {
  id:         "018e5555-6666-7abc-9def-012345678905",
  payment_id: PAYMENT_UUID,
  operation:  "authorize",
  status:     "submitting"
}.freeze

# EIP-3009 refund phase-1 response (signing payload, no tx row).
REFUND_SIGNING_RESPONSE = {
  signing_payload: {
    domain:      { name: "USD Coin", version: "2", chainId: 84532, verifyingContract: TOKEN },
    primaryType: "ReceiveWithAuthorization",
    message:     {}
  }
}.freeze

# Wallet::Restricted
WALLET = { id: WALLET_ID, address: PAYEE, label: "Merchant wallet", active: true }.freeze

# Wallet::Detail (WalletWithTokens) — nested active token holdings.
WALLET_WITH_TOKENS = WALLET.merge(
  tokens: [
    { token: { chain_id: 84532, symbol: "USDC", address: TOKEN, decimals: 6 }, active: true, default: true }
  ]
).freeze

# Balance::Restricted
WALLET_BALANCES = {
  wallet_id: WALLET_ID,
  address:   PAYEE,
  balances: [
    {
      chain_id: 84532, network_type: "testnet",
      native: { symbol: "ETH", address: nil, decimals: 18, raw: "1000000000000000000", amount: "1.0" },
      tokens: [{ symbol: "USDC", address: TOKEN, decimals: 6, raw: "5000000", amount: "5.0" }],
      error: nil
    }
  ]
}.freeze

# Webhook::Restricted / Webhook::WithSecret
WEBHOOK = {
  id: WEBHOOK_ID, name: "orders", callback_url: "https://merchant.example/hook",
  topic: "payments.captured", active: true, circuit_state: "closed",
  circuit_failure_count: 0, created_at: "2026-07-01T00:00:00Z", updated_at: "2026-07-01T00:00:00Z"
}.freeze
WEBHOOK_WITH_SECRET = WEBHOOK.merge(shared_secret: "whsec_test_abc123").freeze

# Dispute::Restricted
DISPUTE = {
  id: "018e7777-8888-7abc-9def-012345678907", payment_id: PAYMENT_UUID, status: "open",
  reason: "0x0000000000000000000000000000000000000000000000000000000000000000",
  opened_block: 123, opened_at: "2026-07-02T00:00:00Z",
  closed_by: nil, close_reason: nil, closed_block: nil, closed_at: nil
}.freeze

# Blockchain::Restricted / Token::Restricted
BLOCKCHAIN = { chain_id: 84532, name: "Base Sepolia", native_symbol: "ETH",
               network_type: "testnet", explorer_url: "https://sepolia.basescan.org" }.freeze
TOKEN_INFO = { chain_id: 84532, symbol: "USDC", address: TOKEN, decimals: 6 }.freeze

# Health
HEALTH = { status: "ok", api_version: "v1", contract_version: "1.2.1", db: "ok",
           active_chains: 1, active_contracts: 1, timestamp: "2026-07-14T00:00:00Z" }.freeze

# Nonce / Session
NONCE_RESPONSE = { nonce: "tEsTn0nce42", expires_at: "2026-06-01T12:00:00Z" }.freeze
SESSION_RESPONSE = { token: "signed.jwt.token", address: PAYER,
                     account_id: ACCOUNT_ID, name: "Merchant", expires_at: "2026-06-02T12:00:00Z" }.freeze
