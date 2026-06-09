# Standard two-step payment flow: authorize → capture
#
# On-chain flow:
#   payer  signs EIP-712 payload  → off-chain
#   payer  PUT /payments/:id/sign → stores signature server-side
#   payee  POST /authorize/prepare → receive unsigned tx
#   payee  signs tx off-chain
#   payee  POST /authorize         → async broadcast (HTTP 202)
#   (poll) GET /payments/:id       → wait for status "authorized"
#   payee  POST /capture/prepare   → receive unsigned tx
#   payee  signs tx off-chain
#   payee  POST /capture           → async broadcast (HTTP 202)
#   (poll) GET /payments/:id       → wait for status "captured"

require "rail0"

PAYER_KEY   = ENV.fetch("PAYER_PRIVATE_KEY")   # 0x-prefixed hex
PAYEE_KEY   = ENV.fetch("PAYEE_PRIVATE_KEY")   # 0x-prefixed hex
ACCOUNT_ID  = ENV.fetch("RAIL0_ACCOUNT_ID")    # UUID
CHAIN_ID    = 5042002                           # Arc Testnet

client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  logger:   Rail0::DEBUG_LOGGER
)

# ----------------------------------------------------------------
# Step 0 — Fetch accepted payment methods for the account (public)
# ----------------------------------------------------------------

result  = client.accounts.wallets(ACCOUNT_ID, chain_id: CHAIN_ID, active: true)
wallets = result[:data]   # paginated — unwrap :data
method  = wallets.find { |w| w[:default] } || wallets.first

puts "Using: #{method[:token_symbol]} on #{method[:chain_name]}"
puts "  token:  #{method[:token_address]}"
puts "  payee:  #{method[:address]}"

# ----------------------------------------------------------------
# Step 1 — Authenticate the payee (JWT)
# ----------------------------------------------------------------

auth_resp = client.auth.login(private_key: PAYEE_KEY, domain: "api.rail0.xyz")
payee_jwt  = auth_resp[:token]

payee_client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  headers:  { "Authorization" => "Bearer #{payee_jwt}" }
)

# ----------------------------------------------------------------
# Step 2 — Create payment intent (payer-side)
# ----------------------------------------------------------------

create_resp = client.payments.create(
  chain_id:    CHAIN_ID,
  mode:        "authorize",
  amount:      "100000000",  # 100 USDC (6 decimals)
  token:       method[:token_address],
  payer:       "0xBuyerAddress000000000000000000000000000000",
  payee:       method[:address],
  metadata:    { order_id: "ORD-123", customer_ref: "CUST-456" }
)

payment_id      = create_resp[:rail0_id]
signing_payload = create_resp[:signing_payload]

puts "\nPayment created: #{payment_id}"

# ----------------------------------------------------------------
# Step 3 — Payer signs the EIP-712 payload off-chain
# ----------------------------------------------------------------
#
# Browser wallet:
#   signature = await window.ethereum.request({
#     method: "eth_signTypedData_v4",
#     params: [payer_address, JSON.stringify(signing_payload)]
#   })
#
# Backend (direct key access) — eth gem:
#   require "eth"
#   key       = Eth::Key.new(priv: PAYER_KEY.delete_prefix("0x"))
#   digest    = Eth::Eip712.hash(signing_payload[:domain], signing_payload[:types], signing_payload[:message])
#   signature = "0x" + key.sign(digest).unpack1("H*")

signature = "0x" + "ab" * 65  # placeholder — replace with real signature

# ----------------------------------------------------------------
# Step 4 — Submit the payer's signature
# ----------------------------------------------------------------

sign_resp = client.payments.sign(payment_id, { signature: signature })
puts "Signature stored. Recovered payer: #{sign_resp[:recovered_payer]}"

# ----------------------------------------------------------------
# Step 5 — Payee prepares the authorize transaction
# ----------------------------------------------------------------

prepare_resp = payee_client.payments.authorize_prepare(payment_id)
puts "\nUnsigned authorize tx: #{prepare_resp[:unsigned_transaction][0, 20]}..."

# ----------------------------------------------------------------
# Step 6 — Payee signs the tx off-chain, then submits
# ----------------------------------------------------------------
#
#   signed_tx = wallet.sign_transaction(prepare_resp[:unsigned_transaction])

signed_tx = "0x02f8ab"  # placeholder — replace with real signed tx

payee_client.payments.authorize(payment_id, { signed_transaction: signed_tx })
puts "Authorize submitted (202). Polling..."

# ----------------------------------------------------------------
# Step 7 — Poll until authorized
# ----------------------------------------------------------------

loop do
  state = client.payments.get(payment_id)
  puts "  status: #{state[:status]}"
  break if state[:status] == "authorized"
  raise "Payment failed: #{state[:failure_code]} — #{state[:failure_message]}" if state[:status] == "failed"
  sleep 2
end

on_chain = client.payments.get(payment_id)[:on_chain]
puts "\nAuthorized. capturable_amount: #{on_chain[:capturable_amount]}"

# ----------------------------------------------------------------
# Step 8 — Prepare a (partial) capture
# ----------------------------------------------------------------

capture_prepare = payee_client.payments.capture_prepare(payment_id, { amount: "50000000" })
puts "\nUnsigned capture tx: #{capture_prepare[:unsigned_transaction][0, 20]}..."

signed_capture = "0x02f9ab"  # placeholder

payee_client.payments.capture(payment_id, { signed_transaction: signed_capture })

loop do
  state = client.payments.get(payment_id)
  puts "  status: #{state[:status]}"
  break if %w[captured partially_captured].include?(state[:status])
  raise "Capture failed: #{state[:failure_code]}" if state[:status] == "failed"
  sleep 2
end

puts "\nDone. Payment captured."

# ----------------------------------------------------------------
# Step 9 — Inspect transaction history (paginated)
# ----------------------------------------------------------------

txs_resp = client.payments.transactions(payment_id)
txs_resp[:data].each do |tx|   # paginated — unwrap :data
  puts "  #{tx[:operation]} #{tx[:status]} #{tx[:transaction_hash]}"
end
