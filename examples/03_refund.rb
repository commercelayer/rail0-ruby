# Refund a previously captured (or charged) payment.
#
# Refund uses EIP-3009 receiveWithAuthorization — no separate ERC-20 approve.
#
# Two-phase prepare:
#   Phase 1: refund_prepare(amount:)              → returns signing_payload
#   Phase 2: refund_prepare(amount:, signature:)  → returns unsigned tx
#   Submit:  refund(signed_transaction:)          → async broadcast (HTTP 202)
#   (poll)   wait for status "refunded"

require "rail0"
require "rail0/signing"

PAYEE_KEY  = ENV.fetch("PAYEE_PRIVATE_KEY")
PAYMENT_ID = ENV.fetch("RAIL0_PAYMENT_ID")   # UUID or 0x-prefixed rail0_id

client = Rail0::Client.new(base_url: "https://api.rail0.xyz", logger: Rail0::DEBUG_LOGGER)

# Authenticate the payee (refund is a payee/JWT operation).
auth = client.auth.login(private_key: PAYEE_KEY, domain: "api.rail0.xyz")
payee = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  headers:  { "Authorization" => "Bearer #{auth[:token]}" }
)

state = payee.payments.get(PAYMENT_ID)
puts "status: #{state[:status]}  refundable: #{state[:refundable_amount]}"

refund_amount = "50000000"  # 50 USDC

# ── Phase 1 — get the EIP-3009 signing payload ────────────────────────────────
p1  = payee.payments.refund_prepare(PAYMENT_ID, amount: refund_amount)
sig = Rail0::Signing.sign_payload(PAYEE_KEY, p1[:signing_payload])

# ── Phase 2 — get the unsigned refund tx ──────────────────────────────────────
p2  = payee.payments.refund_prepare(PAYMENT_ID, amount: refund_amount, signature: sig.to_hex)
raw = Rail0::Signing.sign_transaction(p2[:unsigned_transaction], PAYEE_KEY)

# ── Submit + poll ─────────────────────────────────────────────────────────────
payee.payments.refund(PAYMENT_ID, { signed_transaction: raw })
puts "Refund submitted (202). Polling…"

loop do
  state = client.payments.get(PAYMENT_ID)
  puts "  status: #{state[:status]}  refundable: #{state[:refundable_amount]}"
  break if state[:status] == "refunded" || state[:refundable_amount] == "0"
  raise "refund failed: #{state[:last_error_code]}" if state[:status] == "failed"
  sleep 2
end
puts "Done — refund complete."

# Review the refund transactions (paginated).
payee.payments.transactions(PAYMENT_ID, operation: "refund")[:data].each do |tx|
  puts "  refund #{tx[:status]} block=#{tx[:block_number]} amount=#{tx[:amount]}"
end
