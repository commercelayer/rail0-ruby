# rail0-ruby

Ruby SDK for the [RAIL0](https://github.com/commercelayer/rail0) stablecoin payment gateway.

RAIL0 is an immutable smart contract that brings the authorize → capture → refund
lifecycle of card networks to stablecoin (USDC / EIP-3009) payments — no
intermediaries, no protocol fees, no permission required. This SDK is a REST client
for the RAIL0 gateway that sits in front of the contract, covering the full payment
lifecycle plus account, wallet, catalog, and webhook management. It mirrors the
[rail0-go](https://github.com/commercelayer/rail0-go) and
[rail0-ts](https://github.com/commercelayer/rail0-ts) SDKs.

## Requirements

- Ruby ≥ 2.6
- For SIWE login and off-chain signing: `eth` (`~> 0.5`) and `siwe-rb` (`~> 0.2`)

The core HTTP client has **no runtime dependencies** (Ruby stdlib only). The `eth`
and `siwe-rb` gems are loaded lazily — `require "rail0"` works without them, and
they are needed only when you call `client.auth.login` or `Rail0::Signing`.

## Installation

Add to your Gemfile:

```ruby
gem "rail0"

# Only if you use SIWE login or off-chain signing:
gem "eth",     "~> 0.5"
gem "siwe-rb", "~> 0.2"
```

## Quick start

A full authorize → capture flow. Every on-chain operation is two-phase: a
`*_prepare` call returns an unsigned transaction, which you sign locally with
`Rail0::Signing.sign_transaction`, then the matching submit call broadcasts it.

```ruby
require "rail0"
require "rail0/signing"

client = Rail0::Client.new(base_url: "https://api.rail0.xyz")

# 1. Payer creates the payment — response embeds the EIP-3009 signing payload.
payment = client.payments.create(
  chain_id: 84532,
  mode:     "authorize",
  amount:   "50000000",       # 50 USDC (6 decimals)
  token:    "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  payer:    "0xBuyer…",
  payee:    "0xMerchant…"
)
rail0_id = payment[:rail0_id]

# 2. Payer signs the EIP-3009 payload off-chain and deposits the signature.
sig = Rail0::Signing.sign_payload(BUYER_PRIVATE_KEY, payment[:signing_payload])
client.payments.sign(rail0_id, { signature: sig.to_hex })

# 3. Payee prepares + broadcasts the on-chain authorize tx (signs it locally).
prep = client.payments.authorize_prepare(rail0_id)
raw  = Rail0::Signing.sign_transaction(prep[:unsigned_transaction], MERCHANT_PRIVATE_KEY)
client.payments.authorize(rail0_id, { signed_transaction: raw })   # HTTP 202 (async)

# 4. Poll until the authorization confirms.
loop do
  state = client.payments.get(rail0_id)
  break if state[:status] == "authorized"
  sleep 2
end

# 5. Payee captures the escrowed funds (partial capture is supported).
cap = client.payments.capture_prepare(rail0_id, "50000000")
raw = Rail0::Signing.sign_transaction(cap[:unsigned_transaction], MERCHANT_PRIVATE_KEY)
client.payments.capture(rail0_id, { signed_transaction: raw })
```

All methods return a `Hash` with symbol keys (or raise `Rail0::ApiError`). A
payment id argument accepts either the payment UUID or its `rail0_id` (bytes32).

## Payment lifecycle

Each on-chain operation is a `prepare` → `submit` pair:

1. **prepare** — `client.payments.<op>_prepare(...)` returns a transaction whose
   `unsigned_transaction` is the EIP-1559 field-set to sign.
2. **sign** — `Rail0::Signing.sign_transaction(unsigned, private_key)` returns the
   signed raw tx.
3. **submit** — `client.payments.<op>(id, { signed_transaction: raw })` broadcasts
   it. The gateway acknowledges with HTTP 202 and confirms asynchronously — poll
   `client.payments.get(id)` until the status settles.

Wallets that sign **and** broadcast in one step (e.g. MetaMask via
`eth_sendTransaction`) skip steps 2–3 and report the hash instead:

```ruby
client.payments.submit_by_hash(rail0_id, "capture", { transaction_hash: "0x…" })
```

| Operation | Caller | What it does |
|-----------|--------|--------------|
| `authorize_prepare` + `authorize` | payee | Broadcast the authorize tx; funds move to escrow |
| `charge_prepare` + `charge` | payee | One-shot authorize + capture; no escrow window |
| `capture_prepare` + `capture` | payee | Move escrowed funds to the merchant (partial supported) |
| `void_prepare` + `void` | payee | Cancel the hold, return funds to the payer (only before any capture) |
| `release_prepare` + `release` | anyone | Return uncaptured escrow to the payer |
| `refund_prepare` (phase 1+2) + `refund` | payee | Return captured funds to the payer via EIP-3009 |
| `dispute_prepare` + `dispute` | payer | Open a dispute (signal-only) |
| `close_dispute_prepare` + `close_dispute` | payer | Close an open dispute |

**Payment statuses:** `unsigned`, `signed`, `authorized`, `charged`, `captured`,
`partially_captured`, `voided`, `released`, `refunded`.
**Transaction statuses:** `pending`, `submitting`, `submitted`, `confirmed`, `failed`.

## Authentication (SIWE)

JWT-protected endpoints (wallet management, webhooks, `payments.list`) need a
Sign-In With Ethereum token. `login` runs the full handshake; pass the returned
token to the client via `headers`.

```ruby
auth = client.auth.login(private_key: "0x…", domain: "api.rail0.xyz")
# => { token:, address:, account_id:, name:, expires_at: }
# login embeds chain_id 1 by default; pass chain_id: to match a gateway whose
# SIWE_CHAIN_ID policy differs (e.g. login(private_key:, domain:, chain_id: 5042002)).

authed = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  headers:  { "Authorization" => "Bearer #{auth[:token]}" }
)
```

Lower-level building blocks are also available:

```ruby
nonce   = client.auth.nonce                                  # POST /auth/nonces
session = client.auth.verify(message: siwe_msg, signature: sig)  # POST /auth
```

## Catalog (public)

```ruby
client.chains.list                                    # GET /blockchains
client.chains.list(network_type: "testnet", symbol: "ETH")
client.tokens.list                                    # GET /tokens
client.tokens.list(chain_id: 84532, symbol: "USDC")
```

## Health

```ruby
client.health.get   # GET /health → { status:, api_version:, contract_version:, db:, … }
```

## Payment methods (public discovery)

Buyer-facing discovery of a merchant's accepted wallets/tokens — no JWT. Provide
**exactly one** of `account_id` or `address`.

```ruby
client.payment_methods.list(account_id: "018e…")   # all the merchant's wallets
client.payment_methods.list(address: "0xMerchant…") # just that wallet
```

## Wallets (account-scoped, JWT)

Wallets live under `/accounts/{account_id}/wallets`; every method takes the
account id first. `id_or_address` accepts the wallet UUID or its 0x address.

```ruby
client.wallets.list(account_id, chain_id: 84532, active: true)
# => { data: [ { id:, address:, label:, active:, tokens: [...] } ], meta: { page:, per_page:, total: } }

client.wallets.get(account_id, id_or_address)
client.wallets.create(account_id, address: "0x…", label: "Treasury")
client.wallets.update(account_id, id_or_address, label: "Renamed", active: false)
client.wallets.delete(account_id, id_or_address)                    # 204
client.wallets.balances(account_id, id_or_address, chain_id: 84532) # live on-chain balances
```

## Payments

```ruby
client.payments.create(params, idempotency_key: nil)  # or keyword fields
client.payments.get(id)
client.payments.list(status: "authorized", disputed: false, chain_id: 84532, sort: "-created_at")
client.payments.transactions(id, operation: "capture")
client.payments.sign(id, { signature: "0x…" })
client.payments.disputes(id, status: "open")   # one payment's dispute history

# Account-level: every dispute (open AND closed) across your payments, each with
# the parent payment embedded. A closed dispute drops out of the payments
# `disputed` filter (current-state) but still appears here.
client.disputes.list(status: "closed", sort: "-opened_at")
```

`payments.list`/`transactions`/`disputes` and `disputes.list` return a paginated
`{ data:, meta: { page:, per_page:, total: } }` envelope.

### Refund (two-phase EIP-3009)

```ruby
# Phase 1 — amount only → returns a signing payload for the payee to sign.
p1  = client.payments.refund_prepare(rail0_id, amount: "20000000")
sig = Rail0::Signing.sign_payload(MERCHANT_PRIVATE_KEY, p1[:signing_payload])

# Phase 2 — amount + signature → returns the unsigned on-chain tx.
p2  = client.payments.refund_prepare(rail0_id, amount: "20000000", signature: sig.to_hex)
raw = Rail0::Signing.sign_transaction(p2[:unsigned_transaction], MERCHANT_PRIVATE_KEY)
client.payments.refund(rail0_id, { signed_transaction: raw })
```

### Disputes (payer-driven)

Disputes are authorized on-chain by the payer (no JWT) and follow the same
prepare → submit pattern:

```ruby
prep = client.payments.dispute_prepare(rail0_id, reason: "0x…") # reason optional
raw  = Rail0::Signing.sign_transaction(prep[:unsigned_transaction], BUYER_PRIVATE_KEY)
client.payments.dispute(rail0_id, { signed_transaction: raw })
# … later …
client.payments.close_dispute_prepare(rail0_id)
client.payments.close_dispute(rail0_id, { signed_transaction: raw })
```

### Generic prepare/submit

Every wrapper delegates to the generic form, useful for dynamic operations:

```ruby
client.payments.prepare(id, "capture", { amount: "1" })
client.payments.submit(id, "capture", { signed_transaction: raw })
client.payments.submit_by_hash(id, "capture", { transaction_hash: "0x…" })
```

## Webhooks (JWT)

A webhook subscribes to exactly one topic (see `Rail0::Resources::Webhooks::TOPICS`).

```ruby
hook = client.webhooks.create(
  name: "orders", callback_url: "https://merchant.example/hook", topic: "payments.captured"
)
hook[:shared_secret]                 # shown once — verify delivery signatures with it

client.webhooks.list(topic: "payments.captured", active: true)
client.webhooks.get(id)
client.webhooks.update(id, callback_url: "https://new.example/hook")
client.webhooks.enable(id)
client.webhooks.disable(id)
client.webhooks.rotate_secret(id)    # returns a fresh shared_secret
client.webhooks.reset_circuit(id)
client.webhooks.event_callbacks(id, status: "failed")
client.webhooks.delete(id)           # 204
```

## Signing helpers (`Rail0::Signing`)

Requires the `eth` gem. No private key ever leaves your process.

| Method | Use |
|--------|-----|
| `sign_payload(private_key, signing_payload)` | Sign the EIP-3009 payload from a create/refund response (picks Transfer vs Receive by `primaryType`) — the recommended path |
| `sign_transaction(unsigned_transaction, private_key)` | Sign a prepare step's unsigned EIP-1559 transaction; returns the 0x raw tx |
| `sign_transfer_with_authorization(private_key, domain, params)` | Raw EIP-3009 `TransferWithAuthorization` signer |
| `sign_authorize(params)` / `sign_charge(params)` | Lower-level payer signers built from an explicit `SignPaymentParams` |

```ruby
require "rail0/signing"
sig = Rail0::Signing.sign_payload(BUYER_PRIVATE_KEY, payment[:signing_payload])
client.payments.sign(rail0_id, { signature: sig.to_hex })
```

## Logging

Pass any callable as `logger` to receive a `Rail0::LogEntry` per request attempt.

```ruby
client = Rail0::Client.new(base_url: "https://api.rail0.xyz", logger: Rail0::DEBUG_LOGGER)
# [rail0] GET 200 https://.../payments/0x… 87ms

# Or route into your own logger:
log = Logger.new($stdout)
client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  logger: ->(e) { e.error ? log.error("rail0: #{e.error}") : log.debug("rail0: #{e.method} #{e.status} #{e.duration_ms}ms") }
)
```

## Error handling

Non-2xx responses raise `Rail0::ApiError`:

```ruby
begin
  client.payments.capture(rail0_id, { signed_transaction: raw })
rescue Rail0::ApiError => e
  e.status   # 422
  e.error    # "not_capturable"  (machine-readable code)
  e.message  # human-readable description
end
```

## Configuration

```ruby
Rail0::Client.new(
  base_url:    "https://api.rail0.xyz",
  headers:     { "Authorization" => "Bearer …" }, # for JWT-protected endpoints
  timeout:     30,                                # seconds (default 30)
  max_retries: 0,                                 # network-error retries (default 0)
  retry_delay: 0.2,                               # base delay, doubles each attempt
  logger:      Rail0::DEBUG_LOGGER                # optional
)
```

Only network errors and timeouts are retried; HTTP error responses are not.

## Project structure

```text
gen/generate.rb        regenerates lib/rail0/types.rb from the gateway OpenAPI schema

lib/rail0/
  client.rb            Rail0::Client — entry point
  http_client.rb       internal HTTP client (Net::HTTP, retry, pagination, logging)
  api_error.rb         Rail0::ApiError
  signing.rb           EIP-3009 + EIP-1559 signing (requires 'eth')
  stablecoins.rb       stablecoin address registry
  types.rb             generated Struct docs of the gateway schema (reference only)
  version.rb           Rail0::VERSION
  resources/
    auth.rb            SIWE authentication
    chains.rb          public blockchain catalog
    tokens.rb          public token catalog
    health.rb          gateway health check
    payment_methods.rb public payment-method discovery
    wallets.rb         account-scoped wallet management (JWT)
    payments.rb        payment lifecycle + disputes
    webhooks.rb        webhook subscription management (JWT)
    query.rb           shared query-string helper
```

## Development

```bash
bundle install
bundle exec rspec        # run the test suite

# Regenerate lib/rail0/types.rb after a gateway schema change:
#   defaults to ../rail0-gateway/docs/openapi.json, or set RAIL0_SCHEMA_PATH.
ruby gen/generate.rb
```

## License

[MIT](LICENSE)
