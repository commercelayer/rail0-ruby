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

client = Rail0::Client.new(
  base_url: 'https://api.rail0.xyz',
  headers:  { 'Authorization' => 'Bearer <jwt>' }
)

# Step 1 — list wallets for an account
wallets = client.accounts.wallets('acct_abc123')
wallet = wallets.first

# Step 2 — pick a token accepted by that wallet
tokens = client.wallets.tokens(wallet['id'])
usdc = tokens.find { |t| t['symbol'] == 'USDC' }

# Step 3 — payer creates payment intent
resp = client.payments.create(
  chain_id: usdc['blockchain']['chain_id'],
  mode:     'authorize',
  amount:   '50000000',      # 50 USDC (6 decimals)
  payer:    '0xBuyer...',
  payee:    wallet['address'],
  token:    usdc['address']
)
payment_id = resp['rail0_id']

# Step 4 — payer signs the EIP-3009 payload off-chain
require 'rail0/signing'
sig = Rail0::Signing.sign_payload(
  '0x...',                                          # payer's private key
  resp['signingPayload'].transform_keys(&:to_sym)   # from create
)

# Step 5 — payer submits the signature (single 65-byte hex string)
client.payments.sign(payment_id, signature: sig.to_hex)

# Step 6 — payee prepares the unsigned authorize tx
tx = client.payments.authorize_prepare(payment_id)
# tx['unsignedTransaction'] — RLP-encoded EIP-1559 tx, sign with payee's key

# Step 7 — payee broadcasts the signed authorize tx (async, HTTP 202)
signed_tx = sign_eip1559(tx['unsignedTransaction'])  # your signing logic
result = client.payments.authorize(payment_id, signed_transaction: signed_tx)
# result['status'] => "submitting"

# Step 8 — poll until status leaves "submitting"
loop do
  state = client.payments.get(payment_id)
  break unless state['status'] == 'submitting'
  sleep 2
end

# Step 9 — payee captures the funds
capture_tx = client.payments.capture_prepare(payment_id, amount: '50000000')
client.payments.capture(payment_id, signed_transaction: sign_eip1559(capture_tx['unsignedTransaction']))
```

## Payment lifecycle

```text
                            authorizationExpiry       refundExpiry
                                   │                       │
  ─────────────────────────────────┼───────────────────────┼──────▶ time
   create → sign → authorize_prepare│  capture_prepare/void_prepare │   refund_prepare (phase 1+2)
                   + authorize      │  + capture/void               │   + refund
                                    │   release_prepare + release    │
```

| Operation | Caller | What it does |
|-----------|--------|--------------|
| `authorize_prepare` + `authorize` | payee | Prepare + broadcast the authorize tx; funds move to escrow |
| `charge_prepare` + `charge` | payee | One-shot authorize + capture in a single tx; no escrow window |
| `capture_prepare` + `capture` | payee | Moves escrowed funds to the merchant |
| `void_prepare` + `void` | payee | Cancels the hold, returns funds to the payer |
| `release_prepare` + `release` | anyone | Reclaims escrow after `authorizationExpiry` |
| `refund_prepare` (phase 1+2) + `refund` | payee | Returns captured funds to the payer via EIP-3009 |

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

### `client.accounts`

#### `.wallets(account_id, active: nil, page: nil, per_page: nil)`

List wallets registered to an account.

```ruby
wallets = client.accounts.wallets('acct_abc123')
active  = client.accounts.wallets('acct_abc123', active: true)
# [{ 'id', 'account_id', 'address', 'label', 'active', 'created_at', 'updated_at' }]
```

#### `.wallet(account_id, wallet_id)`

Fetch a single wallet.

```ruby
wallet = client.accounts.wallet('acct_abc123', 'wlt_xyz789')
```

#### `.create_wallet(account_id, address:, label: nil)`

Register a new EVM wallet address. Requires authentication.

```ruby
wallet = client.accounts.create_wallet('acct_abc123', address: '0xABC...', label: 'Treasury')
```

#### `.update_wallet(account_id, wallet_id, label: nil, active: nil)`

Update label or active status. Requires authentication.

```ruby
wallet = client.accounts.update_wallet('acct_abc123', 'wlt_xyz789', active: false)
```

#### `.delete_wallet(account_id, wallet_id)`

Remove a wallet from an account. Requires authentication.

```ruby
client.accounts.delete_wallet('acct_abc123', 'wlt_xyz789')
```

---

### `client.wallets`

#### `.tokens(wallet_id, symbol: nil, active: nil, page: nil, per_page: nil)`

List the tokens accepted by a wallet. Each token includes a nested `blockchain` hash.

```ruby
tokens = client.wallets.tokens('wlt_xyz789')
usdc   = client.wallets.tokens('wlt_xyz789', symbol: 'USDC').first
# token: { 'id', 'symbol', 'address', 'decimals', 'active', 'blockchain' => { 'chain_id', 'name', 'slug', ... } }
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

Possible status values: `pending`, `signed`, `submitting`, `submitted`, `authorized`, `captured`, `partially_captured`, `voided`, `released`, `refunded`, `partially_refunded`, `failed`.

#### `.create(params)`

Creates a payment intent and returns the EIP-712 signing payload for the payer.

```ruby
resp = client.payments.create(
  chain_id: 5042002,
  mode:     'authorize',  # or 'charge'
  amount:   '50000000',
  payer:    '0x...',
  payee:    '0x...',
  token:    '0x...'
)
# resp['rail0_id']        — bytes32 identifier
# resp['signingPayload']  — EIP-712 payload for the payer to sign
# resp['rail0Contract']   — RAIL0 contract address on the target chain
```

#### `.sign(payment_id, params)`

Submits the payer's EIP-712 signature as a single 65-byte hex string (0x-prefixed, 132 chars).

```ruby
client.payments.sign(payment_id, signature: '0x...')
# → { paymentId, status, recoveredPayer }
```

#### `.authorize_prepare(payment_id)` / `.authorize(payment_id, params)`

Prepares and submits the `authorize()` transaction. Called by the payee.
Requires the payer's signature to have been stored via `.sign`.

```ruby
tx = client.payments.authorize_prepare(payment_id)
# sign tx['unsignedTransaction'] with the payee's key
client.payments.authorize(payment_id, signed_transaction: signed_tx)
```

#### `.charge_prepare(payment_id)` / `.charge(payment_id, params)`

Prepares and submits the one-shot authorize + capture transaction. Called by the payee.
Requires the payer's signature (`mode: 'charge'`) to have been stored via `.sign`.

```ruby
tx = client.payments.charge_prepare(payment_id)
client.payments.charge(payment_id, signed_transaction: signed_tx)
```

#### `.capture_prepare(payment_id, params)` / `.capture(payment_id, params)`

Builds and submits the capture transaction. Partial captures are supported.

```ruby
tx = client.payments.capture_prepare(payment_id, amount: '50000000')
client.payments.capture(payment_id, signed_transaction: signed_tx)
```

#### `.void_prepare(payment_id)` / `.void(payment_id, params)`

Builds and submits the void transaction. Cancels the authorization and releases all escrowed funds to the payer. Called by the payee.

```ruby
tx = client.payments.void_prepare(payment_id)
client.payments.void(payment_id, signed_transaction: signed_tx)
```

#### `.release_prepare(payment_id, params = {})` / `.release(payment_id, params)`

Builds and submits the release transaction. Returns escrowed funds to the payer after `authorizationExpiry`. Pass `caller_address:` to build the tx for the buyer (payer); defaults to the payee.

```ruby
tx = client.payments.release_prepare(payment_id, caller_address: buyer_address)
client.payments.release(payment_id, signed_transaction: signed_tx)
```

#### `.refund_prepare(payment_id, amount:, signature: nil)` / `.refund(payment_id, params)`

Two-phase EIP-3009 refund flow. Partial refunds are supported.

Phase 1 — get the signing payload:
```ruby
phase1 = client.payments.refund_prepare(payment_id, amount: '50000000')
# phase1['signing_payload'] — sign off-chain to obtain a 0x-prefixed hex signature
```

Phase 2 — get the unsigned transaction:
```ruby
phase2 = client.payments.refund_prepare(payment_id, amount: '50000000', signature: '0x...')
# phase2['unsigned_transaction'] — sign and submit
client.payments.refund(payment_id, signed_transaction: signed_tx)
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
  amount:           resp['payment']['amount'],
  nonce:            resp['signingPayload']['message']['nonce'],
  contract_address: resp['rail0Contract'],
  token_domain:     Rail0::Signing::TokenDomain.new(
    name:               'USD Coin',
    version:            '2',
    chain_id:           5042002,
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
  client.payments.authorize(payment_id, signed_transaction: signed_tx)
rescue Rail0::ApiError => e
  puts e.status   # 422
  puts e.code     # "AuthorizationExpired"
  puts e.message  # human-readable description
end
```

Common error codes:

| Code | Cause |
|------|-------|
| `PaymentAlreadyExists` | `authorize_prepare`/`charge_prepare` called twice for the same `paymentId` |
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
    accounts.rb     Rail0::Resources::Accounts  (wallet CRUD)
    wallets.rb      Rail0::Resources::Wallets   (wallet tokens)
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
