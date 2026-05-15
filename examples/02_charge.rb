# One-shot payment: charge (authorize + capture in a single transaction)
#
# Funds go directly to the payee with no hold period.
# Use this when the merchant can fulfil the order immediately.

require "rail0"

client = Rail0::Client.new(base_url: "https://api.rail0.xyz")

PAYMENT_ID = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

now = Time.now.to_i

payment = {
  payer:               "0xBuyerAddress000000000000000000000000000000",
  payee:               "0xMerchantAddress0000000000000000000000000000",
  token:               "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  maxAmount:           "100000000",
  authorizationExpiry: now + 60 * 60 * 24,
  refundExpiry:        now + 60 * 60 * 24 * 7,
  feeBps:              50,
  feeReceiver:         "0xFeeReceiverAddress000000000000000000000000"
}

# Fetch the charge-specific nonce (different from the authorize nonce)
nonce = client.payments.charge_nonce(PAYMENT_ID, payment[:payer])[:nonce]

begin
  charge_tx = client.payments.charge(PAYMENT_ID, {
    payment: payment,
    amount:  "25000000", # 25 USDC
    v:       27,
    r:       "0x1111111111111111111111111111111111111111111111111111111111111111",
    s:       "0x2222222222222222222222222222222222222222222222222222222222222222"
  })
  puts "Charged: #{charge_tx[:transactionHash]} — status: #{charge_tx[:status]}"
rescue Rail0::ApiError => e
  puts "Charge failed [#{e.error}]: #{e.message}"
  raise
end
