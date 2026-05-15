# Refund a previously captured payment.
#
# After capture the merchant holds the funds.
# They can refund before refund_expiry.

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

state = client.payments.get(PAYMENT_ID)
puts "Refundable: #{state[:state][:refundableAmount]}"

begin
  refund_tx = client.payments.refund(PAYMENT_ID, {
    payment: payment,
    amount:  "50000000"
  })
  puts "Refunded: #{refund_tx[:transactionHash]} — status: #{refund_tx[:status]}"
rescue Rail0::ApiError => e
  # Common errors: RefundExpired, InvalidRefundAmount, PaymentMismatch
  puts "Refund failed [#{e.error}]: #{e.message}"
  raise
end
