# frozen_string_literal: true

# Merchant payout: move the wallet's balance to a venue (exchange, Circle Mint, …)
#
#   merchant registers the deposit address   → POST /payout_destinations (min_amount, confirm_details: true)
#   merchant sends the small proof transfer  → POST /payouts/prepare (purpose: proof) → sign → submit
#   (poll) waits for the proof to confirm    → GET  /payouts/:id
#   merchant confirms the venue credited it  → POST /payout_destinations/:id/confirm
#   merchant pays out                        → POST /payouts/prepare → verify → sign → submit
#   (poll) waits for status "confirmed"      → GET  /payouts/:id
#
# Payouts.sign_and_submit verifies the prepared ERC-20 transfer (token, chain, recipient,
# amount, value 0, nothing trailing) BEFORE the key signs it, and raises
# Rail0::TxVerify::RefusedSignature otherwise.

require "rail0"
require "rail0/signing"

MERCHANT_KEY  = ENV.fetch("PAYEE_PRIVATE_KEY")      # the wallet that holds the balance, 0x hex
WALLET_ID     = ENV.fetch("RAIL0_WALLET_ID")        # that wallet's uuid (or its address)
CHAIN_ID      = Integer(ENV.fetch("RAIL0_CHAIN_ID", "5042002"))
TOKEN         = ENV.fetch("RAIL0_TOKEN")            # the token's address on that chain
DEPOSIT_ADDR  = ENV.fetch("VENUE_DEPOSIT_ADDRESS")  # generated at the venue FOR THIS NETWORK
VENUE_MINIMUM = ENV.fetch("VENUE_MIN_AMOUNT")       # the venue's minimum deposit, base units; "0" for none
AMOUNT        = ENV.fetch("PAYOUT_AMOUNT", "all")   # a human decimal, or "all"

GATEWAY = "https://api.rail0.xyz"
DOMAIN  = "api.rail0.xyz" # must be one of the gateway's allowed SIWE domains

auth = Rail0::Client.new(base_url: GATEWAY).auth.login(private_key: MERCHANT_KEY, domain: DOMAIN)
api  = Rail0::Client.new(
  base_url: GATEWAY,
  headers:  { "Authorization" => "Bearer #{auth[:token]}" },
  logger:   Rail0::DEFAULT_LOGGER
)

# Poll a payout until it settles. A failure's reason is its error_code (reverted,
# foreign_transfer, dropped, submission_timeout, cancelled).
def wait_for_payout(api, id)
  loop do
    payout = api.payouts.get(id)
    puts "  payout #{id}: #{payout[:status]}"
    return payout if payout[:status] == "confirmed"
    raise "payout #{id} failed: #{payout[:error_code]} #{payout[:error_detail]}" if payout[:status] == "failed"

    sleep 5
  end
end

# ── Step 1 — register the destination, with the merchant's confirmation ────────────
# confirm_details: true is the merchant's acceptance of this exact text (details_v1).
# In an app, show it and pass what the merchant answered; here, running the script is
# the acceptance.
puts Rail0::Resources::PayoutDestinations::CONFIRM_DETAILS_TEXT
dest = api.payout_destinations.create(
  wallet_id: WALLET_ID, chain_id: CHAIN_ID, token: TOKEN, address: DEPOSIT_ADDR,
  label: "My exchange", kind: "exchange", min_amount: VENUE_MINIMUM,
  confirm_details: true
)
puts "Destination #{dest[:id]} — #{dest[:status]}"

# ── Step 2 — the proof transfer (the proof amount, raised to the venue's minimum) ──
proof = api.payouts.prepare(destination_id: dest[:id], purpose: "proof")
puts "Proof of #{proof[:amount_formatted]} #{proof[:token_symbol]} to #{proof[:address]}"
api.payouts.sign_and_submit(proof, MERCHANT_KEY, destination: dest)
wait_for_payout(api, proof[:id])

# ── Step 3 — check at the venue that the proof was CREDITED, then confirm ──────────
puts "Check the venue credited the proof, then press Enter"
$stdin.gets
dest = api.payout_destinations.confirm(dest[:id])
puts "Destination #{dest[:id]} — #{dest[:status]}"

# ── Step 4 — the payout: prepare → verify → sign → submit ─────────────────────────
payout = api.payouts.prepare(destination_id: dest[:id], amount: AMOUNT)
puts "Paying out #{payout[:amount_formatted]} #{payout[:token_symbol]}"
# An explicit amount is also held to what was asked, scaled by the token's decimals.
decimals = api.tokens.list(chain_id: CHAIN_ID).find { |t| t[:address].casecmp(TOKEN).zero? }&.dig(:decimals)
check = AMOUNT == "all" ? {} : { amount: AMOUNT, decimals: decimals }
api.payouts.sign_and_submit(payout, MERCHANT_KEY, destination: dest, **check)

# ── Step 5 — poll until confirmed ─────────────────────────────────────────────────
wait_for_payout(api, payout[:id])
puts "Done."
