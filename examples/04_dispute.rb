# Open and close a dispute on a payment.
#
# Disputes are payer-driven and authorized on-chain (no JWT). They are
# signal-only: opening a dispute flips the payment's `disputed` flag; it does not
# move funds. The payer follows the same prepare → sign → submit pattern as any
# other on-chain operation.

require "rail0"
require "rail0/signing"

PAYER_KEY  = ENV.fetch("PAYER_PRIVATE_KEY")   # the payer signs dispute txs
PAYMENT_ID = ENV.fetch("RAIL0_PAYMENT_ID")    # UUID or 0x-prefixed rail0_id

client = Rail0::Client.new(base_url: "https://api.rail0.xyz", logger: Rail0::DEBUG_LOGGER)

# ── Open a dispute ────────────────────────────────────────────────────────────
# reason is an optional bytes32 code; omit it to default to zero server-side.
prep = client.payments.dispute_prepare(PAYMENT_ID)
raw  = Rail0::Signing.sign_transaction(prep[:unsigned_transaction], PAYER_KEY)
client.payments.dispute(PAYMENT_ID, { signed_transaction: raw })
puts "Dispute submitted (202). Polling…"

loop do
  state = client.payments.get(PAYMENT_ID)
  puts "  disputed: #{state[:disputed]}"
  break if state[:disputed]
  sleep 2
end

# Inspect the dispute history.
client.payments.disputes(PAYMENT_ID)[:data].each do |d|
  puts "  dispute #{d[:status]} opened_at=#{d[:opened_at]} reason=#{d[:reason]}"
end

# ── Close the dispute (e.g. after resolving it off-platform) ──────────────────
prep = client.payments.close_dispute_prepare(PAYMENT_ID)
raw  = Rail0::Signing.sign_transaction(prep[:unsigned_transaction], PAYER_KEY)
client.payments.close_dispute(PAYMENT_ID, { signed_transaction: raw })

loop do
  state = client.payments.get(PAYMENT_ID)
  puts "  disputed: #{state[:disputed]}"
  break unless state[:disputed]
  sleep 2
end
puts "Done — dispute closed."
