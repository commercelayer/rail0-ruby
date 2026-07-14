# One-shot payment: charge (authorize + capture in a single transaction)
#
# Funds move to the payee immediately with no escrow window. Use this when the
# merchant can fulfil the order right away.
#
#   payer creates (mode: "charge") → signs payload → deposits signature
#   payee prepares → signs → broadcasts the charge tx
#   (poll) waits for status "charged"

require "rail0"
require "rail0/signing"

PAYER_KEY  = ENV.fetch("PAYER_PRIVATE_KEY")
PAYEE_KEY  = ENV.fetch("PAYEE_PRIVATE_KEY")
ACCOUNT_ID = ENV.fetch("RAIL0_ACCOUNT_ID")
BUYER      = ENV.fetch("PAYER_ADDRESS")

client = Rail0::Client.new(base_url: "https://api.rail0.xyz", logger: Rail0::DEBUG_LOGGER)

# ── Step 0 — discover a merchant USDC wallet (public) ─────────────────────────
wallet  = client.payment_methods.list(account_id: ACCOUNT_ID)
              .find { |w| w[:tokens].any? { |t| t[:token][:symbol] == "USDC" } }
raise "no active USDC wallet" unless wallet

token = wallet[:tokens].find { |t| t[:token][:symbol] == "USDC" }[:token]
puts "Using #{token[:symbol]} on chain #{token[:chain_id]}"

# ── Step 1 — payer creates the payment in charge mode ─────────────────────────
payment = client.payments.create(
  chain_id: token[:chain_id],
  mode:     "charge",
  amount:   "25000000",  # 25 USDC
  token:    token[:address],
  payer:    BUYER,
  payee:    wallet[:address],
  metadata: { order_id: "ORD-456" }
)
rail0_id = payment[:rail0_id]
puts "Payment created: #{rail0_id}"

# ── Step 2 — payer signs the EIP-3009 payload and deposits the signature ──────
sig = Rail0::Signing.sign_payload(PAYER_KEY, payment[:signing_payload])
client.payments.sign(rail0_id, { signature: sig.to_hex })

# ── Step 3 — payee prepares, signs, and broadcasts the charge tx ──────────────
prep = client.payments.charge_prepare(rail0_id)
raw  = Rail0::Signing.sign_transaction(prep[:unsigned_transaction], PAYEE_KEY)
client.payments.charge(rail0_id, { signed_transaction: raw })
puts "Charge submitted (202). Polling…"

# ── Step 4 — poll until charged ───────────────────────────────────────────────
loop do
  state = client.payments.get(rail0_id)
  puts "  status: #{state[:status]}"
  break if state[:status] == "charged"
  raise "failed: #{state[:last_error_code]} — #{state[:last_error_message]}" if state[:status] == "failed"
  sleep 2
end
puts "Done — payment charged."
