# Refund a previously captured (or charged) payment.
#
# Refund uses EIP-3009 receiveWithAuthorization — no separate ERC-20
# approve step needed.
#
# Two-phase flow:
#   Phase 1: POST /refund/prepare (amount only)
#            → returns signing_payload for the payee to sign
#   Phase 2: POST /refund/prepare (amount + v, r, s)
#            → returns unsigned tx
#   Submit:  POST /refund (signed_transaction)
#   (poll)   GET /payments/:id → wait for status "refunded" or "partially_refunded"

require "rail0"

PAYEE_KEY  = ENV.fetch("PAYEE_PRIVATE_KEY")
PAYMENT_ID = ENV.fetch("RAIL0_PAYMENT_ID")   # 0x-prefixed bytes32

client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  logger:   Rail0::DEBUG_LOGGER
)

# ----------------------------------------------------------------
# Step 0 — Authenticate the payee
# ----------------------------------------------------------------

auth_resp    = client.auth.login(private_key: PAYEE_KEY, domain: "api.rail0.xyz")
payee_client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  headers:  { "Authorization" => "Bearer #{auth_resp[:token]}" }
)

# ----------------------------------------------------------------
# Step 1 — Check current state
# ----------------------------------------------------------------

state = client.payments.get(PAYMENT_ID)
puts "Payment status:    #{state[:status]}"
puts "On-chain refundable: #{state[:on_chain]&.dig(:refundable_amount)}"

# ----------------------------------------------------------------
# Step 2 — Phase 1: get the EIP-3009 signing payload
# ----------------------------------------------------------------

refund_amount = "50000000"   # 50 USDC

phase1 = payee_client.payments.refund_prepare(PAYMENT_ID, { amount: refund_amount })
signing_payload = phase1[:signing_payload]

puts "\nRefund signing payload received. Sign it with the payee key."

# ----------------------------------------------------------------
# Step 3 — Payee signs the EIP-3009 payload off-chain
# ----------------------------------------------------------------
#
#   require "eth"
#   key    = Eth::Key.new(priv: PAYEE_KEY.delete_prefix("0x"))
#   digest = Eth::Eip712.hash(signing_payload[:domain], signing_payload[:types], signing_payload[:message])
#   sig    = key.sign(digest)
#   v      = sig.unpack1("C*").last          # last byte
#   r      = "0x" + sig[0, 32].unpack1("H*")
#   s      = "0x" + sig[32, 32].unpack1("H*")

v = 27
r = "0x" + "11" * 32   # placeholder
s = "0x" + "22" * 32   # placeholder

# ----------------------------------------------------------------
# Step 4 — Phase 2: build the unsigned refund tx
# ----------------------------------------------------------------

phase2 = payee_client.payments.refund_prepare(PAYMENT_ID, {
  amount: refund_amount,
  v:      v,
  r:      r,
  s:      s
})

puts "\nUnsigned refund tx: #{phase2[:unsigned_transaction][0, 20]}..."

# ----------------------------------------------------------------
# Step 5 — Payee signs the tx and submits
# ----------------------------------------------------------------
#
#   signed_tx = wallet.sign_transaction(phase2[:unsigned_transaction])

signed_tx = "0x02f8ab"  # placeholder

payee_client.payments.refund(PAYMENT_ID, { signed_transaction: signed_tx })
puts "Refund submitted (202). Polling..."

# ----------------------------------------------------------------
# Step 6 — Poll until refunded
# ----------------------------------------------------------------

loop do
  state = client.payments.get(PAYMENT_ID)
  puts "  status: #{state[:status]}"
  break if %w[refunded partially_refunded].include?(state[:status])
  raise "Refund failed: #{state[:failure_code]} — #{state[:failure_message]}" if state[:status] == "failed"
  sleep 2
end

puts "\nDone. Refund complete."

# ----------------------------------------------------------------
# Step 7 — Review transaction history (paginated)
# ----------------------------------------------------------------

txs_resp = payee_client.payments.transactions(PAYMENT_ID, operation: "refund")
txs_resp[:data].each do |tx|   # paginated — unwrap :data
  puts "  refund #{tx[:status]} block=#{tx[:block_number]} amount=#{tx[:amount]}"
end

# ----------------------------------------------------------------
# Step 8 — List all payments for the payee (paginated)
# ----------------------------------------------------------------

payments_resp = payee_client.payments.list(status: "refunded", per_page: 10)
puts "\nRefunded payments (#{payments_resp[:meta][:total]} total):"
payments_resp[:data].each do |p|   # paginated — unwrap :data
  puts "  #{p[:rail0_id]} #{p[:amount]} #{p[:metadata].inspect}"
end
