# Standard two-step payment flow: authorize -> capture
#
# The buyer locks funds in escrow using an EIP-3009 signature (authorize).
# The merchant releases them once the order is fulfilled (capture).
#
# On-chain flow:
#   buyer signs EIP-3009 -> authorize()   funds move buyer -> escrow
#   merchant             -> capture()     funds move escrow -> merchant (minus fee)
#   merchant             -> void()        alternative: funds move escrow -> buyer
#   anyone               -> release()     fallback after authorization_expiry

require "rail0"

client = Rail0::Client.new(base_url: "https://api.rail0.xyz")

PAYMENT_ID = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

now = Time.now.to_i

payment = {
  payer:               "0xBuyerAddress000000000000000000000000000000",
  payee:               "0xMerchantAddress0000000000000000000000000000",
  token:               "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", # USDC on Base
  maxAmount:           "100000000",                  # 100 USDC (6 decimals)
  authorizationExpiry: now + 60 * 60 * 24,           # merchant has 24 h to capture
  refundExpiry:        now + 60 * 60 * 24 * 7,       # refund window: 7 days
  feeBps:              50,                           # 0.5% protocol fee
  feeReceiver:         "0xFeeReceiverAddress000000000000000000000000"
}

# ----------------------------------------------------------------
# Step 1 — Buyer fetches the authorize nonce, signs EIP-3009, calls authorize
# ----------------------------------------------------------------

nonce = client.payments.authorize_nonce(PAYMENT_ID, payment[:payer])[:nonce]

# The buyer builds and signs transferWithAuthorization off-chain:
#
#   require "rail0/signing"
#   token_domain = Rail0::Signing::TokenDomain.new(
#     name:                "USD Coin",
#     version:             "2",
#     chain_id:            8453,
#     verifying_contract:  payment[:token]
#   )
#   sig = Rail0::Signing.sign_authorize(Rail0::Signing::SignPaymentParams.new(
#     private_key:      "0x...",
#     payment:          payment,
#     amount:           50_000_000,
#     nonce:            nonce,
#     contract_address: RAIL0_CONTRACT_ADDRESS,
#     token_domain:     token_domain
#   ))

begin
  auth_tx = client.payments.authorize(PAYMENT_ID, {
    payment: payment,
    amount:  "50000000", # 50 USDC
    v:       27,         # from signature
    r:       "0x1111111111111111111111111111111111111111111111111111111111111111",
    s:       "0x2222222222222222222222222222222222222222222222222222222222222222"
  })

  puts "Authorized: #{auth_tx[:transactionHash]} — status: #{auth_tx[:status]}"
  puts "Nonce used: #{nonce}"
rescue Rail0::ApiError => e
  # Common errors: TokenNotAccepted, InvalidAmount, PaymentAlreadyExists
  puts "Authorize failed [#{e.error}]: #{e.message}"
  raise
end

# ----------------------------------------------------------------
# Step 2a — Merchant captures 50 USDC (happy path)
# ----------------------------------------------------------------

begin
  capture_tx = client.payments.capture(PAYMENT_ID, {
    payment: payment,
    amount:  "50000000"
  })
  puts "Captured: #{capture_tx[:transactionHash]}"
rescue Rail0::ApiError => e
  # Common errors: AuthorizationExpired, InvalidCaptureAmount, PaymentMismatch
  puts "Capture failed [#{e.error}]: #{e.message}"
  raise
end

# ----------------------------------------------------------------
# Inspect on-chain state at any point
# ----------------------------------------------------------------

state = client.payments.get(PAYMENT_ID)
puts "Payment state: #{state[:state]}"
# { exists: true, capturableAmount: "0", refundableAmount: "50000000" }
