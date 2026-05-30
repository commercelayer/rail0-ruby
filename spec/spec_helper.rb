require "webmock/rspec"
require "rail0"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.warnings = true
  config.order = :random
end

# Shared test fixtures
PAYMENT_ID = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
ACCOUNT_ID = "018e1234-5678-7abc-9def-012345678901"
BASE_URL    = "https://api.rail0.xyz"

PAYMENT_INPUT = {
  payer:  "0xBuyerAddress000000000000000000000000000000",
  payee:  "0xMerchantAddress0000000000000000000000000000",
  token:  "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  amount: "100000000"
}.freeze

# PrepareTransactionResponse fixture
PREPARE_RESPONSE = {
  unsignedTransaction:  "0x02f8ab",
  to:                   "0xRail0Contract0000000000000000000000000000",
  data:                 "0x1234abcd",
  chainId:              84532,
  nonce:                42,
  maxFeePerGas:         "1000000000",
  maxPriorityFeePerGas: "1000000000",
  gasLimit:             "200000"
}.freeze

# SubmitTransactionAcceptedResponse fixture (HTTP 202)
SUBMIT_RESPONSE = {
  paymentId: PAYMENT_ID,
  status:    "submitting"
}.freeze

# GetPaymentResponse fixture
PAYMENT_RESPONSE = {
  paymentId:           PAYMENT_ID,
  status:              "authorized",
  mode:                "authorize",
  amount:              "100000000",
  payer:               "0xBuyerAddress000000000000000000000000000000",
  payee:               "0xMerchantAddress0000000000000000000000000000",
  token:               "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  chainId:             84532,
  authorizationExpiry: 9_999_999_999,
  refundExpiry:        9_999_999_999,
  onChain: {
    exists:           true,
    capturableAmount: "100000000",
    refundableAmount: "0"
  }
}.freeze

# PayerSignatureResponse fixture
SIGN_RESPONSE = {
  paymentId:      PAYMENT_ID,
  status:         "signature_stored",
  recoveredPayer: "0xBuyerAddress000000000000000000000000000000"
}.freeze

# PaymentMethod fixture
PAYMENT_METHOD = {
  id:            1,
  tokenId:       7,
  chainId:       84532,
  chainName:     "Base Sepolia",
  tokenAddress:  "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  tokenSymbol:   "USDC",
  tokenDecimals: 6,
  walletAddress: "0xMerchantAddress0000000000000000000000000000",
  isDefault:     true
}.freeze
