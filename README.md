# rail0-ruby

Ruby SDK for the [RAIL0](https://github.com/commercelayer/rail0) stablecoin payment API.

RAIL0 is an immutable smart contract that brings the authorize → capture → refund lifecycle of card networks to stablecoin payments — no intermediaries, no protocol fees, no permission required. This SDK wraps the REST API that sits in front of the contract, giving you fully-typed access to every operation.

## Requirements

- Ruby ≥ 2.6
- For off-chain signing: `eth` gem `~> 0.5`

## Installation

Add to your Gemfile:

```ruby
gem 'rail0'
```

For off-chain EIP-3009 signing support:

```ruby
gem 'rail0'
gem 'eth', '~> 0.5'
```

## Quick start

```ruby
require 'rail0'

client = Rail0::Client.new(base_url: 'https://api.rail0.xyz')

# Step 1 — discover payment methods
methods = client.merchants.payment_methods(1)
usdc = methods.find { |m| m['tokenSymbol'] == 'USDC' }

# Step 2 — payer creates payment intent
resp = client.payments.create(
  payment: {
    payer: '0xBuyer...',
    payee: usdc['walletAddress'],
    token: usdc['tokenAddress'],
  },
  amount: '50000000',        # 50 USDC (6 decimals)
  chainId: usdc['chainId'],
  mode: 'authorize'
)
payment_id = resp['paymentId']

# Step 3 — payer signs the EIP-3009 payload off-chain
require 'rail0/signing'
sig = Rail0::Signing.sign_payload(
  '0x...',                                          # payer's private key
  resp['signingPayload'].transform_keys(&:to_sym)   # from create
)

# Step 4 — payer submits the signature (single 65-byte hex string)
client.payments.sign(payment_id, signature: sig.to_hex)

# Step 5 — payee prepares the unsigned authorize tx
tx = client.payments.prepare_authorize(payment_id)
# tx['unsignedTransaction'] — RLP-encoded EIP-1559 tx, sign with payee's key

# Step 6 — payee broadcasts the signed authorize tx (async, HTTP 202)
signed_tx = sign_eip1559(tx['unsignedTransaction'])  # your signing logic
result = client.payments.submit_transaction(payment_id, signedTransaction: signed_tx)
# result['status'] => "submitting"

# Step 7 — poll until status leaves "submitting"
loop do
  state = client.payments.get(payment_id)
  break unless state['status'] == 'submitting'
  sleep 2
end

# Step 8 — payee captures the funds
capture_tx = client.payments.prepare_capture(payment_id, amount: '50000000')
client.payments.submit_transaction(payment_id, signedTransaction: sign_eip1559(capture_tx['unsignedTransaction']))
```

## Payment lifecycle

```text
                            authorizationExpiry       refundExpiry
                                   │                       │
  ─────────────────────────────────┼───────────────────────┼──────▶ time
   create → sign → prepare_authorize│  prepare_capture/void │   prepare_approve+prepare_refund
                   + submit_transaction│  + submit_transaction│   + submit_transaction each
                                    │   prepare_release      │
```

| Operation | Caller | What it does |
|-----------|--------|--------------|
| `prepare_authorize` + `submit_transaction` | payee | Prepare + broadcast the authorize tx; funds move to escrow |
| `prepare_charge` + `submit_transaction` | payee | One-shot authorize + capture in a single tx; no escrow window |
| `prepare_capture` + `submit_transaction` | payee | Moves escrowed funds to the merchant |
| `prepare_void` + `submit_transaction` | payee | Cancels the hold, returns funds to the payer |
| `prepare_release` + `submit_transaction` | anyone | Reclaims escrow after `authorizationExpiry` |
| `prepare_approve` + `submit_transaction` | payee | ERC-20 `approve()` required before a refund |
| `prepare_refund` + `submit_transaction` | payee | Returns captured funds to the payer |

## API reference

### `Rail0::Client.new(**opts)`

```ruby
client = Rail0::Client.new(
  base_url:    'https://api.rail0.xyz',
  headers:     { 'Authorization' => 'Bearer ...' }, # optional
  timeout:     30,     # seconds, default 30
  max_retries: 3,      # default 0 (no retry)
  retry_delay: 0.2,    # seconds base delay, doubles each attempt
  logger:      Rail0::DEBUG_LOGGER,                  # optional — see Logging
)
```

---

### Logging

Pass any callable (`#call`) as `logger` to receive structured log entries.

```ruby
client = Rail0::Client.new(
  base_url: 'https://api.rail0.xyz',
  logger:   Rail0::DEBUG_LOGGER,
)
```

Output:
```text
[rail0] POST 200 https://.../payments 87ms
[rail0] ERROR PUT https://.../payments/0x.../sign 30001ms ! Net::ReadTimeout
```

To integrate with `Logger` or any structured logging library:

```ruby
log = Logger.new($stdout)

client = Rail0::Client.new(
  base_url: 'https://api.rail0.xyz',
  logger: ->(e) {
    e[:error] ? log.error("rail0: #{e[:error]}") : log.debug("rail0: #{e[:method]} #{e[:status]} #{e[:duration_ms]}ms")
  },
)
```

---

### `client.merchants`

#### `.payment_methods(merchant_id)`

Returns the active payment methods (chain + token + wallet) for a merchant.

```ruby
methods = client.merchants.payment_methods(1)
# [{ 'id', 'chainId', 'chainName', 'chainSlug', 'explorerUrl',
#    'tokenAddress', 'tokenSymbol', 'tokenDecimals',
#    'walletAddress', 'isDefault' }]
```

---

### `client.payments`

All methods return a `Hash` matching the corresponding response schema. Errors raise `Rail0::ApiError`.

#### `.get(payment_id)`

Fetches the current payment state (DB status + live on-chain escrow balances).

```ruby
state = client.payments.get(payment_id)
# state['status']                        → "authorized", "captured", "submitting", …
# state['onChain']['capturableAmount']   → escrowed amount still available
# state['onChain']['refundableAmount']   → captured amount eligible for refund
```

Possible status values: `pending`, `signed`, `submitting`, `submitted`, `authorized`, `captured`, `partially_captured`, `voided`, `released`, `approved`, `refunded`, `partially_refunded`, `failed`.

#### `.create(params)`

Creates a payment intent and returns the EIP-712 signing payload for the payer.

```ruby
resp = client.payments.create(
  payment: { payer: '0x...', payee: '0x...', token: '0x...' },
  amount: '50000000',
  chainId: 84532,
  mode: 'authorize'  # or 'charge'
)
# resp['paymentId']       — bytes32 identifier
# resp['signingPayload']  — EIP-712 payload for the payer to sign
# resp['rail0Contract']   — RAIL0 contract address on the target chain
```

#### `.sign(payment_id, params)`

Submits the payer's EIP-712 signature as a single 65-byte hex string (0x-prefixed, 132 chars).

```ruby
client.payments.sign(payment_id, signature: '0x...')
# → { paymentId, status, recoveredPayer }
```

#### `.prepare_authorize(payment_id)`

Prepares the unsigned `authorize()` transaction. Called by the payee.
Requires the payer's signature to have been stored via `.sign`.
Returns `PrepareTransactionResponse` — sign `unsignedTransaction` with the payee's key and pass to `submit_transaction`.

#### `.prepare_charge(payment_id)`

Prepares the unsigned one-shot authorize + capture transaction. Called by the payee.
Requires the payer's signature (`mode: 'charge'`) to have been stored via `.sign`.
Returns `PrepareTransactionResponse`. Pass the signed tx to `submit_transaction`.

#### `.prepare_capture(payment_id, params)`

Builds the capture transaction. Partial captures are supported — call repeatedly until fully captured or the authorization expires.

```ruby
tx = client.payments.prepare_capture(payment_id, amount: '50000000')
# tx['unsignedTransaction'] — sign and pass to submit_transaction
```

#### `.prepare_void(payment_id)`

Builds the void transaction. Cancels the authorization and releases all escrowed funds to the payer. Called by the payee.

#### `.prepare_release(payment_id, params = {})`

Builds the release transaction. Returns escrowed funds to the payer after `authorizationExpiry`. Pass `callerAddress:` to build the tx for the buyer (payer); defaults to the payee.

```ruby
tx = client.payments.prepare_release(payment_id, callerAddress: buyer_address)
# sign tx['unsignedTransaction'] with buyer's key, then submit_transaction
```

#### `.prepare_approve(payment_id, params)`

Builds an ERC-20 `approve()` to allow the RAIL0 contract to pull funds for a refund. Called by the payee before `.prepare_refund`.

```ruby
tx = client.payments.prepare_approve(payment_id, amount: '50000000')
# sign and submit_transaction, then prepare_refund
```

#### `.prepare_refund(payment_id, params)`

Builds the refund transaction. Partial refunds are supported.

```ruby
tx = client.payments.prepare_refund(payment_id, amount: '50000000')
# sign and submit_transaction
```

#### `.submit_transaction(payment_id, params)`

Broadcasts a signed transaction on-chain. This is the **single submit method** used after every `prepare_*` call. Returns HTTP 202 immediately — the operation is determined server-side from the preceding prepare step.

```ruby
result = client.payments.submit_transaction(payment_id, signedTransaction: signed_tx)
# result['status'] => "submitting"

# Poll get() until status leaves "submitting"
loop do
  state = client.payments.get(payment_id)
  break unless state['status'] == 'submitting'
  sleep 2
end
```

---

## Off-chain signing

Install the `eth` gem, then:

```ruby
require 'rail0/signing'

# Simplest: sign the full signingPayload from the API response
sig = Rail0::Signing.sign_payload(
  '0x...',                                          # payer's private key
  resp['signingPayload'].transform_keys(&:to_sym)   # from create
)

# Pass the resulting signature as a single hex string to sign()
client.payments.sign(payment_id, signature: sig.to_hex)

# Or sign with explicit params (e.g. when you need to reconstruct the payload)
sig = Rail0::Signing.sign_authorize(Rail0::Signing::SignPaymentParams.new(
  private_key:      '0x...',
  payment:          resp['payment'],
  amount:           resp['amount'],
  nonce:            resp['signingPayload']['message']['nonce'],
  contract_address: resp['rail0Contract'],
  token_domain:     Rail0::Signing::TokenDomain.new(
    name:               'USD Coin',
    version:            '2',
    chain_id:           84532,
    verifying_contract: resp['payment']['token'],
  ),
))

client.payments.sign(payment_id, signature: sig.to_hex)
```

Use `sign_charge` instead of `sign_authorize` when `mode: 'charge'`.

---

## Error handling

Non-2xx responses raise `Rail0::ApiError`:

```ruby
begin
  client.payments.submit_transaction(payment_id, signedTransaction: signed_tx)
rescue Rail0::ApiError => e
  puts e.status   # 422
  puts e.code     # "AuthorizationExpired"
  puts e.message  # human-readable description
end
```

Common error codes:

| Code | Cause |
|------|-------|
| `PaymentAlreadyExists` | `prepare_authorize`/`prepare_charge` called twice for the same `paymentId` |
| `PaymentNotFound` | `paymentId` does not exist |
| `AuthorizationExpired` | `authorizationExpiry` is in the past (capture) |
| `AuthorizationNotExpired` | `authorizationExpiry` has not passed yet (release) |
| `RefundExpired` | `refundExpiry` is in the past |
| `InvalidAmount` | `amount` is 0 |
| `NotPayee` | caller is not `payment.payee` |

---

## Project structure

```text
gen/
  generate.rb       regenerates lib/rail0/types.rb from the schema

lib/rail0/
  client.rb         Rail0::Client — entry point
  http_client.rb    internal HTTP client (Net::HTTP, retry, logging)
  api_error.rb      Rail0::ApiError
  signing.rb        EIP-712 / EIP-3009 off-chain signing (requires 'eth' gem)
  stablecoins.rb    stablecoin address registry
  types.rb          Struct definitions generated from the OpenAPI schema
  version.rb        Rail0::VERSION

  resources/
    merchants.rb    Rail0::Resources::Merchants
    payments.rb     Rail0::Resources::Payments
```

---

## Development

```bash
bundle install

# Run tests
bundle exec rake test

# Regenerate lib/rail0/types.rb after an API change:
# 1. Update the schema in rail0-api (sibling repo),
#    or set RAIL0_SCHEMA_PATH to point to a local file.
# 2. Run the generator:
ruby gen/generate.rb
```

---

## License

[MIT](LICENSE)
