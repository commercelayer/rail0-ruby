# rail0-ruby

Ruby SDK for the [RAIL0](https://github.com/rail0/rail0) stablecoin payment API.

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

# Step 1 — payer creates payment intent
resp = client.payments.create_payment(
  payment: {
    payer: '0xBuyer...',
    payee: '0xMerchant...',
    token: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', # USDC on Base
  },
  chainId: 84532,   # Base Sepolia
  mode: 'authorize'
)

payment_id = resp['paymentId']
# resp['payment']['amount'] contains the API-configured payment amount

# Step 2 — payer signs the EIP-3009 payload off-chain
require 'rail0/signing'

sig = Rail0::Signing.sign_payment(
  private_key: '0x...',  # payer's private key
  response: resp
)

# Step 3 — payer submits the signature
client.payments.sign(payment_id, v: sig.v, r: sig.r, s: sig.s)

# Step 4 — payee relays the signature on-chain (authorize)
client.payments.authorize(payment_id)

# Step 5 — payee prepares and submits the capture transaction
tx = client.payments.prepare_capture(payment_id, amount: resp['payment']['amount'])
signed_tx = sign_transaction(tx['unsignedTransaction']) # sign with payee's key
client.payments.submit_capture(payment_id, signedTransaction: signed_tx)
```

## Payment lifecycle

```text
                            authorizationExpiry       refundExpiry
                                   │                       │
  ─────────────────────────────────┼───────────────────────┼──────▶ time
   create → sign → authorize/charge │   prepare+submit       │   refund
                                    │   capture / void       │
                                    │   release              │
```

| Operation | Caller | What it does |
|-----------|--------|--------------|
| `authorize` | payee | Relays the signed EIP-3009 to escrow funds |
| `charge` | payee | Authorize + capture in one transaction |
| `prepare_capture` / `submit_capture` | payee | Moves escrowed funds to the merchant |
| `prepare_void` / `submit_void` | payee | Cancels the hold, returns funds to the payer |
| `release` | anyone | Reclaims escrow after `authorizationExpiry` with no capture |
| `prepare_refund` / `submit_refund` | payee | Returns captured funds to the payer |

## API reference

### `Rail0::Client.new(**opts)`

```ruby
require 'rail0'

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
# Built-in logger — writes one line per request to $stdout
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

### `client.payments`

All methods return a `Hash` matching the corresponding response schema. Errors raise `Rail0::ApiError`.

#### `.create_payment(params)`

Creates a payment intent and returns the EIP-712 signing payload for the payer.

```ruby
resp = client.payments.create_payment(
  payment: { payer: '0x...', payee: '0x...', token: '0x...' },
  chainId: 84532,
  mode: 'authorize'  # or 'charge'
)
# resp['paymentId']       — bytes32 identifier
# resp['payment']         — PaymentConfig (includes API-configured amount, expiries, fees)
# resp['signingPayload']  — EIP-712 payload for the payer to sign
# resp['rail0Contract']   — RAIL0 contract address on the target chain
```

#### `.sign(payment_id, params)`

Submits the payer's EIP-712 signature.

```ruby
client.payments.sign(payment_id, v: sig.v, r: sig.r, s: sig.s)
```

#### `.authorize(payment_id)` / `.charge(payment_id)`

Relays the stored signature on-chain. Called by the payee.

#### `.prepare_capture(payment_id, params)` / `.submit_capture(payment_id, params)`

Build and broadcast the capture transaction. Called by the payee.

```ruby
tx = client.payments.prepare_capture(payment_id, amount: '50000000')
# tx['unsignedTransaction'] — RLP-encoded EIP-1559 tx, ready to sign
client.payments.submit_capture(payment_id, signedTransaction: signed_tx)
```

#### `.prepare_void(payment_id)` / `.submit_void(payment_id, params)`

Build and broadcast the void transaction. Called by the payee.

#### `.release(payment_id)`

Return escrowed funds to the payer after `authorizationExpiry`. Permissionless.

#### `.prepare_approve(payment_id, params)` / `.submit_approve(payment_id, params)`

Build and broadcast an ERC-20 `approve()` to allow the RAIL0 contract to pull funds for a refund.

#### `.prepare_refund(payment_id, params)` / `.submit_refund(payment_id, params)`

Build and broadcast the refund transaction. Called by the payee.

---

## Off-chain signing

Install the `eth` gem, then:

```ruby
require 'rail0/signing'

# Sign using the full API response (recommended)
sig = Rail0::Signing.sign_payment(
  private_key: '0x...',  # payer's private key
  response: resp          # Hash returned by create_payment
)

# Or sign with explicit params
sig = Rail0::Signing.sign_authorize(Rail0::Signing::SignPaymentParams.new(
  private_key:      '0x...',
  payment:          resp['payment'],
  nonce:            resp['signingPayload']['message']['nonce'],
  contract_address: resp['rail0Contract'],
  token_domain:     Rail0::Signing::TokenDomain.new(
    name:               'USD Coin',
    version:            '2',
    chain_id:           84532,
    verifying_contract: resp['payment']['token'],
  ),
))

# sig.v, sig.r, sig.s — pass to client.payments.sign
```

---

## Error handling

Non-2xx responses raise `Rail0::ApiError`:

```ruby
begin
  client.payments.submit_capture(payment_id, signedTransaction: signed_tx)
rescue Rail0::ApiError => e
  puts e.status   # 422
  puts e.code     # "AuthorizationExpired"
  puts e.message  # human-readable description
end
```

Common error codes:

| Code | Cause |
|------|-------|
| `PaymentAlreadyExists` | `authorize`/`charge` relayed twice for the same `paymentId` |
| `PaymentNotFound` | `paymentId` does not exist |
| `PaymentMismatch` | payment config does not match the stored hash |
| `AuthorizationExpired` | `authorizationExpiry` is in the past (capture) |
| `AuthorizationNotExpired` | `authorizationExpiry` has not passed yet (release) |
| `RefundExpired` | `refundExpiry` is in the past |
| `InvalidAmount` | `amount` is 0 |
| `TokenNotAccepted` | token is not in this deployment's allowlist |
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
