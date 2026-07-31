# Gap Analysis: Integrating `rail0-ruby` into core-api's Payment Gateway Framework

## Context

core-api's `PaymentSetting`/`Payment::*` framework was designed against card/redirect
gateways (Stripe, Adyen, Braintree): one HTTP call → a synchronous, gateway-final result →
translate status → drive an AASM transaction. RAIL0 is a settlement protocol with multiple
independent signers and asynchronous on-chain confirmation. This document maps where the
existing framework transfers directly onto RAIL0, and where it genuinely doesn't fit.

This is an analysis, not an implementation plan — no code has been written. Findings are
based on direct reads of both `rail0-ruby` (`Rail0::Client`, `Rail0::Signing`,
`lib/rail0/resources/*`) and core-api (`PaymentSetting` and its Stripe/Adyen subclasses,
`Payment::Client`/`Session`/`Wallet`/`Payload`/`EventHandler` base classes, `db/schema.rb`,
`Gemfile`).

## Where the framework aligns cleanly

| Item | Info | |
|---|---|---|
| STI `PaymentSetting` subclass, secrets in `credentials`/config in `options` | Direct fit — `private_key`, `base_url`, `webhook_shared_secret` as credentials; `chain_id`/`token_contract`/`token_decimals` as options, same shape as `PaymentSettingExternal`. | ✅ |
| `ERROR_CLASSES` consumed by inherited `rescue_and_log` | Direct fit — `Rail0::ApiError` is a single, well-formed exception class (`status`/`error`/`message`), simpler than Stripe/Adyen's SDK-specific hierarchies. | ✅ |
| `PaymentSetting::TYPES` registration | Confirmed by direct code read: referenced in exactly one other place app-wide (`PaymentSession`'s `alias_method` loop) — low-risk, no hidden fan-out. | ✅ |
| Per-gateway HTTP client behind an `api_client` method | Direct fit — `Rail0::Client.new(base_url:, ...)`, same shape as Adyen's real per-instance client (closer analog than Stripe's global-mutation pattern). | ✅ |
| Async/indeterminate settlement | Already supported by existing primitives, not new: `PaymentTransaction`'s `after_commit` succeed/fail cascade fires regardless of timing, and `PaymentSession` already has a generic `_refresh` trigger built for exactly "check again later" — just unused by any gateway today. | ✅ |
| Spec tooling | `Rail0::Request` uses plain `Net::HTTP` — WebMock intercepts it natively, no custom stub-helper needed (simpler than Adyen's `stub_adyen!`). | ✅ |
| Private gem dependency | Precedented via Commerce Layer's own `axerve_client`/`klarna_client`/`satispay_client` gems behind a private registry source block; `rail0` would follow once published. | ✅ |

## Where it genuinely diverges

| Item | Info | |
|---|---|---|
| Payment lifecycle shape | Every existing gateway assumes the merchant can unilaterally authorize/capture. RAIL0 requires the **payer** to sign an EIP-3009 payload from their own wallet first — a step core-api doesn't control the timing of. No existing gateway has this shape; Adyen's `require_action` (3DS) is the closest repurposable state, not a built-for-this pattern. | ❌ |
| "Wallets" mean two unrelated things | core-api's `PaymentWallet`/`Payment::Wallet::*` is a saved *customer* instrument (vaultable card/SetupIntent). RAIL0's `.wallets` resource (confirmed via `lib/rail0/resources/wallets.rb`) is *merchant payout-wallet* management — no per-customer concept at all. Forcing one onto the other would misrepresent the data model. | ❌ |
| Auth model | Every existing gateway uses a static API key. RAIL0's JWT-gated endpoints need a SIWE login producing an expiring token — and `Rail0::Client` freezes itself at construction (confirmed via `lib/rail0/client.rb`), so a JWT-bearing client must be a second, separately-refreshed instance. Genuinely new plumbing. | ❌ |
| Versioning machinery doesn't apply | `Payment::Payload::Base.factory`'s version-resolution and `GATEWAY_VERSIONS` exist for Stripe's dated API / Adyen's checkout version. RAIL0 has neither — using that machinery anyway would add indirection with no payoff. | ❌ |
| Currency model mismatch | Fiat `amount_cents`/`currency_code` vs. RAIL0's token base units/`token_decimals`. Conversion is mechanical; no existing FX story for currency ≠ stablecoin peg. | ❌ |
| No on-chain address concept in the data model | The payer's wallet address has no home today; `client_data` (already used for `gift_card_code`-style params) is the natural candidate but nothing validates it yet. | ❌ |
| Credentials risk class | Every other gateway's secret is a revocable, scope-limited API key in an unencrypted jsonb column. A RAIL0 `private_key` is irrevocable on-chain custody — a leak means direct, unrecoverable fund loss. Storing it the same way "because that's convention" changes the risk calculus materially. | ❌ |
| Webhook signature scheme unconfirmed | core-api has a precedented HMAC pattern (`PaymentSettingExternal`) that likely fits, but RAIL0's actual delivery header/encoding hasn't been verified against a real gateway. Compounded by RAIL0's one-webhook-per-topic model needing a secret *per topic*, not one global secret (see recommended approach, below). | ❌ |
| Void/Release asymmetry | RAIL0 distinguishes pre-capture `void` from remainder-returning `release`; core-api only has one `PaymentVoid` concept. Matters only if partial-capture-then-cancel becomes a real requirement. | ❌ |

## Recommended approach for the async merchant-signing gap

The major gap (payment lifecycle shape, above) is best addressed by making RAIL0's own
webhooks the **primary driver** of state transitions — reusing the framework's existing
`GatewayWebhook` concern + `Payment::EventHandler::Base.factory` dispatch pattern (the same
mechanism Stripe/Adyen already use) — rather than relying on the `_refresh` polling trigger
as the main mechanism. `_refresh` remains valuable as a reconciliation fallback (in case a
webhook is missed or delayed), matching how production Stripe/Adyen integrations already
combine both, but it shouldn't be the *primary* path for something this multi-staged.

The reasoning: RAIL0 stacks two async dependencies — the payer signing, then the merchant
signing — on top of on-chain confirmation latency. Polling alone only tells core-api "check
again later"; it doesn't solve the actual gap, which is *reacting the instant the payer signs*
so the merchant-side prepare→sign→submit step fires with minimal delay, instead of waiting
for the next poll interval to notice. A `payments.signed` webhook is exactly that reactive
trigger.

RAIL0 webhook topic → core-api action mapping:

| RAIL0 topic | core-api action |
|---|---|
| `payments.signed` | Trigger the merchant-side signing step: `prepare` → `Rail0::Signing.sign_transaction` → `submit` for `authorize`/`charge`. This is the reactive replacement for polling on the payer's out-of-band step. |
| `payments.authorized` / `payments.charged` | Settle `PaymentAuthorization` (`transaction.succeed!`). |
| `payments.captured` | Settle `PaymentCapture`. |
| `payments.voided` | Settle `PaymentVoid`. |
| `payments.refunded` | Settle `PaymentRefund`. |
| `payments.failed` | `transaction.fail!`. |
| `payments.disputed` / `payments.dispute_closed` | Optional for a first pass; hook exists in the framework (`Payment::EventHandler`) but no existing gateway's dispute handling was found to model against directly. |

**Structural wrinkle this surfaces**: RAIL0's webhook model is *one webhook per topic*
(`client.webhooks.create(name:, callback_url:, topic:)` takes a single topic, unlike Stripe's
one endpoint subscribing to a list of event types via `enabled_events`). Supporting the
mapping above means registering **multiple separate webhook subscriptions** per
`PaymentSettingRail0` (one per topic above), each returning its **own** `shared_secret`. The
credentials need to store a secret per topic (e.g. a small hash keyed by topic name), not one
global secret — signature verification must look up the right secret per inbound webhook.

Without this webhook-driven mechanism, the only alternative is pure polling, which doesn't
resolve the reactive-timing half of the gap — it only tells core-api "check again later,"
not "act now."

## Open decisions needing a follow-up conversation

| Item | Info | |
|---|---|---|
| Merchant payout-wallet management scope | Is it even wanted, and if so, as a standalone adapter rather than through `PaymentWallet`/`vaultable?`. | ❌ |
| Payer on-chain address plumbing | Where it lives (`client_data` vs. a new column/concern) and who owns validation. | ❌ |
| Currency/stablecoin-peg mismatch | What happens when a market's fiat currency doesn't match the configured stablecoin — hard error, or real multi-currency support? | ❌ |
| SIWE login key vs. signing key | Whether the SIWE-login private key and the on-chain transaction-signing key are meant to be the same wallet in every deployment, or separate credentials. | ❌ |
| `credentials` vs. `options` split | Non-secret config (`chain_id`/`token_contract`/etc.) — minor, but precedent exists both ways in the current codebase. | ❌ |
| Private-key custody | Whether unencrypted `credentials` storage is acceptable even short-term, or this needs a KMS/vault-backed signing design before real funds are at risk. | ❌ |
| Webhook signature format | The actual header/encoding RAIL0 uses for webhook delivery signatures — needs confirming against the real gateway, not assumed from another gateway's shape. | ❌ |
| Gem distribution | `rail0` has no private-registry presence yet; a `path:` dependency only works on machines with `rail0-ruby` checked out as a sibling directory — not CI-safe or shareable until published. | ❌ |

## Verifying this analysis

Since this is an analysis, not a build, "verification" means confirming the assumptions
above hold before anyone commits to implementation.

| Item | Info | |
|---|---|---|
| Ruby/gem compatibility | `bundle install` with a local `path:` entry for `rail0-ruby` plus `eth`/`siwe-rb` against core-api's pinned Ruby (3.3.4) — not yet run; no conflict expected since `rail0-ruby` requires >= 3.0. | ❌ |
| SIWE/JWT shape | Attempt `Rail0::Client#auth.login` from a core-api console against a real/sandbox rail0-gateway instance and inspect the actual `expires_at`/token shape — not yet confirmed. | ❌ |
| Webhook signature format | Confirm directly against the gateway before treating `GatewayWebhook`'s HMAC pattern as a fit rather than a guess. | ❌ |
| Wallets mismatch sign-off | Explicit confirmation needed before any implementation plan is written, since it affects the shape of the first model built. | ❌ |
| Payer-address plumbing sign-off | Same — affects the first model built. | ❌ |

## Files referenced during this analysis

- `/Users/mikecosta/Sites/rail0-ruby/lib/rail0/client.rb`, `resources/wallets.rb`, `signing.rb`, `request.rb`
- `/Users/mikecosta/Sites/core-api/app/models/payment_setting.rb`, `payment_setting_stripe.rb`, `payment_setting_adyen.rb`
- `/Users/mikecosta/Sites/core-api/app/models/payment/client.rb`, `session/base.rb`, `wallet/base.rb`, `wallet/stripe.rb`, `payload/base.rb`, `event_handler/base.rb`
- `/Users/mikecosta/Sites/core-api/app/models/payment_session.rb`, `payment_wallet.rb`
- `/Users/mikecosta/Sites/core-api/app/models/concerns/gateway_webhook.rb`
- `/Users/mikecosta/Sites/core-api/db/schema.rb` (`payment_settings` table)
- `/Users/mikecosta/Sites/core-api/Gemfile`
