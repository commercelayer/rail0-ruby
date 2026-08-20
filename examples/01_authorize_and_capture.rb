# frozen_string_literal: true

# Standard two-step payment flow: authorize → capture
#
#   payer  creates the payment            → POST /payments
#   payer  signs the EIP-3009 payload     → off-chain (Rail0::Signing.sign_payload)
#   payer  deposits the signature         → PUT  /payments/:id/sign
#   payee  prepares + signs + broadcasts  → POST /authorize/prepare → sign → POST /authorize
#   (poll) waits for status "authorized"  → GET  /payments/:id
#   payee  captures (partial supported)   → POST /capture/prepare → sign → POST /capture

require "rail0"
require "rail0/signing"

PAYER_KEY  = ENV.fetch("PAYER_PRIVATE_KEY")   # 0x-prefixed hex
PAYEE_KEY  = ENV.fetch("PAYEE_PRIVATE_KEY")   # 0x-prefixed hex
ACCOUNT_ID = ENV.fetch("RAIL0_ACCOUNT_ID")    # merchant account UUID
BUYER      = ENV.fetch("PAYER_ADDRESS")       # payer's 0x address

GATEWAY = "https://api.rail0.xyz"
DOMAIN  = "api.rail0.xyz" # must be one of the gateway's allowed SIWE domains

# EVERY endpoint under /payments requires a SIWE session, and POST /payments
# additionally requires the caller to BE the payer (403 payer_must_be_caller
# otherwise) — so the payer and the payee each sign in with their own key. The
# JWT is not stored on the client, so each session is its own client.
def session_for(private_key)
  auth = Rail0::Client.new(base_url: GATEWAY).auth.login(private_key: private_key, domain: DOMAIN)
  Rail0::Client.new(
    base_url: GATEWAY,
    headers:  { "Authorization" => "Bearer #{auth[:token]}" },
    logger:   Rail0::DEFAULT_LOGGER
  )
end

public_client = Rail0::Client.new(base_url: GATEWAY, logger: Rail0::DEFAULT_LOGGER)
payer         = session_for(PAYER_KEY)
payee         = session_for(PAYEE_KEY)

# ── Step 0 — discover the merchant's accepted payment methods (the ONE public call) ──
wallets = public_client.payment_methods.list(account_id: ACCOUNT_ID)
wallet  = wallets.first || raise("merchant has no active wallets")
holding = wallet[:tokens].find { |t| t[:default] } || wallet[:tokens].first
token   = holding[:token]

puts "Using #{token[:symbol]} on chain #{token[:chain_id]} → payee #{wallet[:address]}"

# ── Step 1 — payer creates the payment intent ─────────────────────────────────
payment = payer.payments.create(
  chain_id: token[:chain_id],
  mode:     "authorize",
  amount:   "100.00", # human decimals, NOT base units — the gateway scales
  token:    token[:address],
  payer:    BUYER,
  payee:    wallet[:address],
  metadata: { order_id: "ORD-123" }
)
rail0_id = payment[:rail0_id]
puts "Payment created: #{rail0_id}"

# ── Step 2 — payer signs the EIP-3009 payload and deposits the signature ──────
sig = Rail0::Signing.sign_payload(PAYER_KEY, payment[:signing_payload])
payer.payments.sign(rail0_id, { signature: sig.to_hex })

# ── Step 3 — payee prepares, signs, and broadcasts the authorize tx ───────────
prep = payee.payments.authorize_prepare(rail0_id)
raw  = Rail0::Signing.sign_transaction(prep[:unsigned_transaction], PAYEE_KEY)
payee.payments.authorize(rail0_id, { signed_transaction: raw })
puts "Authorize submitted (202). Polling…"

# ── Step 4 — poll until authorized ────────────────────────────────────────────
loop do
  state = payer.payments.get(rail0_id)
  puts "  status: #{state[:status]}"
  break if state[:status] == "authorized"
  raise "failed: #{state[:last_error_code]} — #{state[:last_error_message]}" if state[:status] == "failed"

  sleep 2
end

capturable = payer.payments.get(rail0_id)[:capturable_amount]
puts "Authorized. capturable_amount: #{capturable}"

# ── Step 5 — payee captures (partial capture shown: 50 of 100 USDC) ───────────
cap = payee.payments.capture_prepare(rail0_id, "50.00") # human decimals too
raw = Rail0::Signing.sign_transaction(cap[:unsigned_transaction], PAYEE_KEY)
payee.payments.capture(rail0_id, { signed_transaction: raw })

loop do
  state = payer.payments.get(rail0_id)
  puts "  status: #{state[:status]}"
  break if %w[captured partially_captured].include?(state[:status])
  raise "capture failed: #{state[:last_error_code]}" if state[:status] == "failed"

  sleep 2
end
puts "Done — payment captured."

# ── Step 6 — inspect the transaction history (paginated) ──────────────────────
payee.payments.transactions(rail0_id)[:data].each do |tx|
  puts "  #{tx[:operation]} #{tx[:status]} #{tx[:transaction_hash]}"
end
