# One-shot payment: charge (authorize + capture in a single transaction)
#
# Funds go directly to the payee with no hold period.
# Use this when the merchant can fulfil the order immediately.
#
# On-chain flow:
#   payer  signs EIP-712 payload  → off-chain
#   payer  PUT /payments/:id/sign → stores signature server-side
#   payee  POST /charge/prepare   → receive unsigned tx
#   payee  signs tx off-chain
#   payee  POST /charge           → async broadcast (HTTP 202)
#   (poll) GET /payments/:id      → wait for status "charged"

require "rail0"

PAYER_KEY   = ENV.fetch("PAYER_PRIVATE_KEY")
PAYEE_KEY   = ENV.fetch("PAYEE_PRIVATE_KEY")
ACCOUNT_ID  = ENV.fetch("RAIL0_ACCOUNT_ID")
CHAIN_ID    = 5042002  # Arc Testnet

client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  logger:   Rail0::DEBUG_LOGGER
)

# ----------------------------------------------------------------
# Step 0 — Fetch accepted payment methods (public, paginated)
# ----------------------------------------------------------------

result  = client.accounts.wallets(ACCOUNT_ID, token_symbol: "USDC", active: true)
wallets = result[:data]   # paginated — unwrap :data
method  = wallets.first || raise("No active USDC wallet found")

puts "Using: #{method[:token_symbol]} on #{method[:chain_name]}"

# ----------------------------------------------------------------
# Step 1 — Authenticate the payee
# ----------------------------------------------------------------

auth_resp    = client.auth.login(private_key: PAYEE_KEY, domain: "api.rail0.xyz")
payee_client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  headers:  { "Authorization" => "Bearer #{auth_resp[:token]}" }
)

# ----------------------------------------------------------------
# Step 2 — Create payment intent in charge mode
# ----------------------------------------------------------------

create_resp = client.payments.create(
  chain_id:    CHAIN_ID,
  mode:        "charge",
  amount:      "25000000",  # 25 USDC
  token:       method[:token_address],
  payer:       "0xBuyerAddress000000000000000000000000000000",
  payee:       method[:address],
  metadata:    { order_id: "ORD-456" }
)

payment_id      = create_resp[:rail0_id]
signing_payload = create_resp[:signing_payload]

puts "\nPayment created: #{payment_id}"

# ----------------------------------------------------------------
# Step 3 — Payer signs the EIP-712 payload off-chain
# ----------------------------------------------------------------
#
#   signature = wallet.sign_typed_data(signing_payload)

signature = "0x" + "ab" * 65  # placeholder

client.payments.sign(payment_id, { signature: signature })
puts "Signature stored."

# ----------------------------------------------------------------
# Step 4 — Payee prepares the charge transaction
# ----------------------------------------------------------------

prepare_resp = payee_client.payments.charge_prepare(payment_id)
puts "\nUnsigned charge tx: #{prepare_resp[:unsigned_transaction][0, 20]}..."

# ----------------------------------------------------------------
# Step 5 — Payee signs and submits
# ----------------------------------------------------------------
#
#   signed_tx = wallet.sign_transaction(prepare_resp[:unsigned_transaction])

signed_tx = "0x02f8ab"  # placeholder

payee_client.payments.charge(payment_id, { signed_transaction: signed_tx })
puts "Charge submitted (202). Polling..."

# ----------------------------------------------------------------
# Step 6 — Poll until charged
# ----------------------------------------------------------------

loop do
  state = client.payments.get(payment_id)
  puts "  status: #{state[:status]}"
  break if state[:status] == "charged"
  raise "Payment failed: #{state[:failure_code]} — #{state[:failure_message]}" if state[:status] == "failed"
  sleep 2
end

puts "\nDone. Payment charged successfully."
