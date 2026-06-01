# Standard two-step payment flow: authorize → capture
#
# On-chain flow:
#   payer  signs EIP-3009     → off-chain
#   payee  PUT /sign          → stores signature server-side
#   payee  POST /authorize    → get unsigned tx
#   payee  signs tx off-chain → signed tx
#   payee  POST /transactions/submit  → async broadcast (HTTP 202)
#   (poll) GET  /payments/:id → wait for status "authorized"
#   payee  POST /capture      → get unsigned tx
#   payee  signs tx off-chain → signed tx
#   payee  POST /transactions/submit  → async broadcast (HTTP 202)
#   (poll) GET  /payments/:id → wait for status "captured"

require "rail0"

client = Rail0::Client.new(base_url: "https://api.rail0.xyz")

MERCHANT_ID = "018e1234-5678-7abc-9def-012345678901"
CHAIN_ID    = 84532  # Base Sepolia

# ----------------------------------------------------------------
# Step 0 — Fetch accepted payment methods for the merchant
# ----------------------------------------------------------------

methods = client.merchants.payment_methods(MERCHANT_ID)
method  = methods.find(&:dig.curry[:isDefault]) || methods.first

puts "Using payment method: #{method[:tokenSymbol]} on #{method[:chainName]}"
puts "  token:  #{method[:tokenAddress]}"
puts "  payee:  #{method[:walletAddress]}"

# ----------------------------------------------------------------
# Step 1 — Create payment intent (buyer-side)
# ----------------------------------------------------------------

create_resp = client.payments.create(
  payment: {
    payer:  "0xBuyerAddress000000000000000000000000000000",
    payee:  method[:walletAddress],
    token:  method[:tokenAddress],
    amount: "100000000"  # 100 USDC (6 decimals)
  },
  chainId: CHAIN_ID,
  mode:    "authorize"
)

payment_id     = create_resp[:paymentId]
signing_prepare = create_resp[:signingPayload]

puts "\nPayment created: #{payment_id}"

# ----------------------------------------------------------------
# Step 2 — Buyer signs the EIP-712 payload off-chain
# ----------------------------------------------------------------
#
# Browser wallets:
#   signature = await window.ethereum.request({
#     method: "eth_signTypedData_v4",
#     params: [buyer_address, JSON.stringify(signing_prepare)]
#   })
#
# Backend (direct key access):
#   require "eth"
#   key     = Eth::Key.new(priv: "0x...")
#   digest  = Eth::Eip712.hash(signing_prepare[:domain], signing_prepare[:types], signing_prepare[:message])
#   signature = key.sign(digest)

signature = "0x" + "ab" * 65  # placeholder — replace with real signature

# ----------------------------------------------------------------
# Step 3 — Submit the payer's signature (payee-side)
# ----------------------------------------------------------------

sign_resp = client.payments.sign(payment_id, { signature: })
puts "Signature stored. Recovered payer: #{sign_resp[:recoveredPayer]}"

# ----------------------------------------------------------------
# Step 4 — Prepare the authorize transaction (payee-side)
# ----------------------------------------------------------------

prepare_resp = client.payments.prepare_authorize(payment_id)
puts "\nUnsigned tx ready: #{prepare_resp[:unsignedTransaction][0, 20]}..."

# ----------------------------------------------------------------
# Step 5 — Payee signs the transaction off-chain, then submits
# ----------------------------------------------------------------
#
#   signed_tx = wallet.sign_transaction(prepare_resp[:unsignedTransaction])

signed_tx = "0x02f8ab"  # placeholder — replace with real signed tx

submit_resp = client.payments.submit_transaction(payment_id, { signedTransaction: signed_tx })
puts "Submitted. Status: #{submit_resp[:status]}"  # => "submitting"

# ----------------------------------------------------------------
# Step 6 — Poll until authorized
# ----------------------------------------------------------------

loop do
  state = client.payments.get(payment_id)
  puts "  status: #{state[:status]}"
  break if state[:status] == "authorized"
  raise "Payment failed: #{state[:failureCode]} — #{state[:failureMessage]}" if state[:status] == "failed"

  sleep 2
end

on_chain = client.payments.get(payment_id)[:onChain]
puts "\nAuthorized. capturableAmount: #{on_chain[:capturableAmount]}"

# ----------------------------------------------------------------
# Step 7 — Prepare a (partial) capture
# ----------------------------------------------------------------

capture_prepare = client.payments.prepare_capture(payment_id, { amount: "50000000" })
puts "\nCapture tx ready: #{capture_prepare[:unsignedTransaction][0, 20]}..."

signed_capture = "0x02f9ab"  # placeholder

client.payments.submit_transaction(payment_id, { signedTransaction: signed_capture })

loop do
  state = client.payments.get(payment_id)
  puts "  status: #{state[:status]}"
  break if state[:status] == "captured"
  raise "Capture failed: #{state[:failureCode]}" if state[:status] == "failed"

  sleep 2
end

puts "\nDone. Payment captured successfully."
