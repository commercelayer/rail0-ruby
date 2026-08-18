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

- Ruby ≥ 3.0
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

**The whole `/payments` surface is authenticated**, and `create` requires the
caller to be the payer — so sign in first (see
[Authentication](#authentication-siwe)).

```ruby
require "rail0"
require "rail0/signing"

GATEWAY = "https://api.rail0.xyz"

# 0. Sign in as the payer — POST /payments requires payer == caller.
auth   = Rail0::Client.new(base_url: GATEWAY).auth.login(private_key: BUYER_PRIVATE_KEY, domain: "api.rail0.xyz")
client = Rail0::Client.new(base_url: GATEWAY, headers: { "Authorization" => "Bearer #{auth[:token]}" })

# 1. Payer creates the payment — response embeds the EIP-3009 signing payload.
payment = client.payments.create(
  chain_id: 84532,
  mode:     "authorize",
  amount:   "50.00",          # human decimals, NOT base units
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
cap = client.payments.capture_prepare(rail0_id, "50.00")
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
`partially_captured`, `voided`, `released`, `refunded` — plus `partially_refunded`,
which is no longer produced (a partial refund deliberately leaves the status alone)
but is still a legal value on historical rows, so don't write an exhaustive `case`
that raises on it.
**Transaction statuses:** `pending`, `submitting`, `submitted`, `confirmed`, `failed`.

## Authentication (SIWE)

Sign-In With Ethereum gates **the entire `/payments` sub-tree** (create, sign,
every prepare/submit, reads and list) plus wallet management, webhooks, disputes
and analytics. The public surface is small: `chains`, `tokens`, `health` and
`payment_methods` (buyer-facing discovery). `login` runs the full handshake; pass
the returned token to the client via `headers`.

Two role rules are worth knowing before the first call, because both surface as a
403 rather than a validation error:

- `payments.create` requires the caller to **be the payer** (`payer_must_be_caller`);
- the merchant operations (authorize, capture, charge, void, refund) are
  **payee-only**, while `release` and the prepare steps accept either participant,
  and `dispute`/`close_dispute` submits are **payer-only**.

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

For a long-lived process, pass a **callable** instead of a fixed header so one
shared client survives a token refresh — it is resolved per request:

```ruby
client = Rail0::Client.new(base_url: GATEWAY, token: -> { Current.rail0_jwt })
```

A String `token:` works for the simple case, and an explicit `Authorization` in
`headers` still takes precedence.

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

Which tokens a wallet accepts — this is what `payment_methods` then exposes to
buyers, so it is the last step of merchant onboarding:

```ruby
holding = client.wallets.add_token(account_id, id_or_address, chain_id: 84532, token: "0x…", default: true)
client.wallets.enable_token(account_id, id_or_address, holding[:id])
client.wallets.disable_token(account_id, id_or_address, holding[:id])  # keeps the holding
client.wallets.remove_token(account_id, id_or_address, holding[:id])   # 204, soft delete
```

`add_token` is idempotent by (wallet, chain, token): re-adding an existing holding
re-enables it and answers 200 instead of creating a second row. The id passed to
the other three is the **holding's** id, not the token address.

## Payments

```ruby
client.payments.create(params, idempotency_key: nil)  # or keyword fields
# Reusing a key for DIFFERENT terms raises Rail0::ApiError with code
# "idempotency_key_reused" (422) instead of returning the first payment.
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

Every payment row carries `chain_id`, list rows included. You need it to display
an amount: `amount` is in base units and the token's decimals resolve from
`token` **plus** its chain — an address alone identifies a token only within one
chain — so a listing never needs a `get(id)` per row to render totals.

### Refund (two-phase EIP-3009)

```ruby
# Phase 1 — amount only → returns a signing payload for the payee to sign.
p1  = client.payments.refund_prepare(rail0_id, amount: "20.00")
sig = Rail0::Signing.sign_payload(MERCHANT_PRIVATE_KEY, p1[:signing_payload])

# Phase 2 — amount + signature → returns the unsigned on-chain tx.
p2  = client.payments.refund_prepare(rail0_id, amount: "20.00", signature: sig.to_hex)
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

### Verifying a delivery

Every delivery carries `X-Rail0-Topic`, `X-Rail0-Timestamp` and
`X-Rail0-Signature` — a hex HMAC-SHA256 over `"{timestamp}.{body}"` keyed by the
webhook's `shared_secret`.

```ruby
# Rack / Rails controller
def receive
  raw = request.body.read

  unless Rail0::WebhookSignature.verify(
    body:      raw,                                     # the RAW body, not a re-serialised hash
    signature: request.headers["X-Rail0-Signature"],
    timestamp: request.headers["X-Rail0-Timestamp"],
    secret:    ENV.fetch("RAIL0_WEBHOOK_SECRET")
  )
    return head :unauthorized
  end

  handle(JSON.parse(raw, symbolize_names: true))
  head :ok
end
```

The timestamp is inside the signed string on purpose, and `verify` rejects one
outside ±300s (`tolerance:` to change it) **even when the digest matches** — that
window is what bounds a replay of a captured delivery. Pass the body exactly as
received: re-serialising a parsed hash changes key order and whitespace, and the
digest with it. Comparison is constant-time.

## Analytics (JWT)

Account-scoped: the numbers are the merchant's own, so a buyer's account-less token is
refused with `account_required`.

```ruby
client.analytics.summary(status: "captured")
# => { count: 42, disputed_count: 1 }

# Volume needs BOTH token and chain_id — amounts in different tokens (or the same symbol
# on different chains) are different units, and summing them would produce a number that
# looks meaningful and isn't.
client.analytics.summary(token: usdc, chain_id: 84_532)
# => { count: 12, disputed_count: 0, volume: { token: "0x…", chain_id: 84532, total: "12000000" } }

client.analytics.timeseries(interval: "day", from: "2026-07-01T00:00:00Z")
# => [{ bucket: "2026-07-01", count: 3 }, …]  oldest first

client.analytics.breakdown(by: "chain")
# => [{ chain_id: 84532, count: 9 }, …]   by: token | chain | mode | status
```

All three take the same filters — `mode`, `status`, `token`, `chain_id`, `from`, `to` — so
the same question can be asked at three resolutions: one total, a series over time, a split
by dimension. Token and chain rows carry per-token volume; mode and status rows are counts
only, for the reason above.

## Signing helpers (`Rail0::Signing`)

Requires the `eth` gem. No private key ever leaves your process.

| Method | Use |
|--------|-----|
| `sign_payload(signer, signing_payload)` | Sign the EIP-3009 payload from a create/refund response — the recommended path, and the only one that follows the gateway across contract versions |
| `sign_transaction(unsigned_transaction, key)` | Sign a prepare step's unsigned EIP-1559 transaction; returns the 0x raw tx |
| `sign_transfer_with_authorization(signer, domain, params)` | Raw EIP-3009 `TransferWithAuthorization` signer, for talking to a token directly |

```ruby
require "rail0/signing"
sig = Rail0::Signing.sign_payload(BUYER_PRIVATE_KEY, payment[:signing_payload])
client.payments.sign(rail0_id, { signature: sig.to_hex })
```

**The gateway builds the payload; you sign it verbatim.** `sign_payload` takes the
typehash from the payload's `primaryType` and every field from its `message` — only
the gateway knows which contract version a payment lives on, and the version selects
the typehash, the EIP-712 domain and the field layout. An unrecognised `primaryType`
raises rather than falling back, because a guessed typehash yields a *valid*
signature over the wrong digest, which fails only on-chain, after gas.

`sign_authorize` / `sign_charge` were removed for that reason — they rebuilt the
digest from a payment record. They raise with a pointer here.

### Signing without a raw key

`sign_payload` and `sign_transfer_with_authorization` accept a private-key String,
an `Eth::Key`, or **any object responding to `#sign(digest)`** that returns a
65-byte hex signature — a KMS or HSM client, a remote signer, a hardware-wallet
bridge. The SDK builds the EIP-712 digest and hands only that over, so the secret
need never be materialised as a String in your process:

```ruby
class KmsSigner
  def sign(digest) = MyKms.sign(key_id: KEY_ID, digest: digest)  # -> "0x…" (65 bytes)
end

sig = Rail0::Signing.sign_payload(KmsSigner.new, payment[:signing_payload])
```

`sign_transaction` is narrower on purpose: `Eth::Tx#sign` derives an EIP-155 `v`
from the chain id, so it needs a full `Eth::Key` (a String or an `Eth::Key`), not a
bare digest signer.

## Logging

Pass any callable as `logger` to receive a `Rail0::LogEntry` per request attempt.

```ruby
client = Rail0::Client.new(base_url: "https://api.rail0.xyz", logger: Rail0::DEFAULT_LOGGER)
# D, [...] DEBUG -- : [rail0] GET 200 https://.../payments/0x… 87ms

# Rail0::DefaultLogger is a Logger subclass, so it takes any Logger.new argument:
client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  logger:   Rail0::DefaultLogger.new("rail0.log", level: Logger::WARN)
)

# Or route into your own logger:
log = Logger.new($stdout)
client = Rail0::Client.new(
  base_url: "https://api.rail0.xyz",
  logger: ->(e) { e.error ? log.error("rail0: #{e.error}") : log.debug("rail0: #{e.method} #{e.status} #{e.duration_ms}ms") }
)
```

## Error handling

Non-2xx responses raise `Rail0::ApiError`, carrying the gateway's code/title/detail
triple:

```ruby
begin
  client.payments.capture(rail0_id, { signed_transaction: raw })
rescue Rail0::ApiError => e
  e.status  # 422
  e.error   # "insufficient_token_balance" — branch on this, and only this
  e.title   # "Not enough balance" — a heading
  e.detail  # a sentence you can show a user verbatim (also e.message)
  e.hint    # this SDK's own extra advice, nil when it has none
end
```

**`error` is the only field to branch on.** It is the specific condition, read from the
gateway's `code` and falling back to the older `error` sub-code and then to `status` (the
wider family), so an older gateway still yields the most specific value it sent.

`title` and `detail` come from the gateway's error catalogue, so the same condition always
reads the same way whichever endpoint surfaced it; `detail` is written to be shown to a
user as-is.

`hint` (or `Rail0.describe_error(code)`) is this SDK's own advice — a *supplement* to
`detail`, present only for codes with a next step worth adding. The codes span four
families, and the last two are the ones most requests actually hit, neither raised by
RAIL0 itself:

| Family | Examples |
| --- | --- |
| Request & state guards | `not_capturable`, `amount_exceeds_refundable`, `not_the_payee` |
| RAIL0 custom errors | `not_payee`, `already_captured`, `refund_expired` |
| Token reverts | `insufficient_token_balance`, `invalid_token_signature`, `authorization_already_used` |
| Broadcast rejections | `insufficient_gas_funds`, `nonce_too_low`, `replacement_underpriced` |

A failed transaction carries the same triple as `error_code`, `error_title` and
`error_detail`, whether it reverted on-chain or was refused before broadcast.

## Configuration

```ruby
Rail0::Client.new(
  base_url:    "https://api.rail0.xyz",
  headers:     { "Authorization" => "Bearer …" }, # for JWT-protected endpoints
  timeout:     30,                                # seconds (default 30)
  max_retries: 0,                                 # network-error retries (default 0)
  retry_delay: 0.2,                               # base delay, doubles each attempt
  retry_on_429: false,                            # retry a rate limit (default false)
  retry_after_cap: 60,                            # longest Retry-After to honour, seconds
  logger:      Rail0::DEFAULT_LOGGER               # optional
)
```

### Rate limits

The gateway throttles two surfaces independently: the public, unauthenticated one **per
IP** (100 requests / 60s by default — SIWE nonce + verify, `/payment_methods`, the
catalog reads, `/health`) and everything authenticated **per session**, keyed on the
JWT's subject (300 / 60s). Over budget it answers **429** with `code: "rate_limited"` and
a `Retry-After`.

`Rail0::ApiError#retry_after` carries that header as whole seconds — nil on every other
error, and nil when the header is absent or unusable. Read it rather than guessing:

```ruby
begin
  client.payments.list
rescue Rail0::ApiError => e
  raise unless e.error == "rate_limited"
  sleep(e.retry_after || 5)   # the gateway's own pacing
end
```

Note what the number means: the gateway sends **the whole throttle period**, not the time
left in the current window, so it is an upper bound on the wait rather than a measurement.

`retry_on_429: true` makes the SDK do that waiting for you — Retry-After, clamped to
`retry_after_cap`, plus a little jitter (see `Rail0::Backoff`; callers sharing one session
are told the same number and would otherwise wake in lockstep). It is **off by default**
on purpose: an automatic sleep hides back-pressure from the process that could react to
it, and in a request/response app it turns a rate limit into a stalled page. Turn it on in
a job — and note it sleeps the **calling thread**. It also works on its own: you do not
need to set `max_retries` as well (that pairing would make the flag a silent no-op).

Only network errors, timeouts and — when opted in — a 429 are retried; no other HTTP
error is. The 429 is safe to retry on **any** method, `POST` included, because the
gateway rejects it in middleware before the request reaches the application: nothing ran,
so nothing can run twice. That is not true of a 502 or a timeout on a capture, where the
broadcast may already be in flight.

## Project structure

```text
gen/generate.rb        regenerates lib/rail0/types.rb from the gateway OpenAPI schema

lib/rail0/
  client.rb            Rail0::Client — entry point
  http_client.rb       thin per-verb facade (get/post/put/patch/delete) over Request
  request.rb           Rail0::Request — one HTTP call: retry, pagination, error mapping, logging
  default_logger.rb    Rail0::LogEntry + Rail0::DefaultLogger (Logger subclass) for `logger:`
  api_error.rb         Rail0::ApiError (code/title/detail + #hint)
  error_hints.rb       Rail0.describe_error — per-code next steps, shared with the other SDKs
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
    analytics.rb       account-scoped payment analytics (JWT)
    query.rb           shared query-string helper
```

## Development

```bash
bundle install
bundle exec rake         # run the test suite (default task)

# Regenerate lib/rail0/types.rb after a gateway schema change:
#   defaults to ../rail0-gateway/docs/openapi.json, or set RAIL0_SCHEMA_PATH.
ruby gen/generate.rb
```

## License

[MIT](LICENSE)
