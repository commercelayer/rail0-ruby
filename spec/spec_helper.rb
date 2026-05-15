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
BASE_URL   = "https://api.rail0.xyz"

PAYMENT = {
  payer:               "0xBuyerAddress000000000000000000000000000000",
  payee:               "0xMerchantAddress0000000000000000000000000000",
  token:               "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  maxAmount:           "100000000",
  authorizationExpiry: 9_999_999_999,
  refundExpiry:        9_999_999_999,
  feeBps:              50,
  feeReceiver:         "0xFeeReceiverAddress000000000000000000000000"
}.freeze

TX_RESPONSE = {
  transactionHash: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  status:          "pending"
}.freeze

PAYMENT_RESPONSE = {
  paymentId:  PAYMENT_ID,
  state:      { exists: true, capturableAmount: "50000000", refundableAmount: "0" },
  configHash: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
}.freeze
