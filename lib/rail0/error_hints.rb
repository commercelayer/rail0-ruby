# frozen_string_literal: true

module Rail0
  # Actionable next steps per error code, supplementing the gateway's own `detail`.
  # Shared source with the Go SDK (rail0.DescribeError), the TS SDK (describeError) and
  # the CLI's hints — keep the four in step.
  ERROR_HINTS = {
    "amount_exceeds_capturable" => "amount is above the capturable balance — check capturableAmount on the payment",
    "amount_exceeds_refundable" => "amount is above the refundable balance — check refundableAmount on the payment",
    "not_capturable" => "the payment must be 'authorized' or 'partially_captured' to capture",
    "not_voidable" => "void is only allowed while 'authorized' with nothing captured — use release for the remainder after a capture",
    "not_releasable" => "release opens only after authorizationExpiry",
    "not_refundable" => "nothing is refundable — the payment must be charged/captured and within the refund window",
    "not_signable" => "the payment must be 'unsigned' to sign",
    "already_signed" => "the payer signature is already stored — the payee can act now",
    "no_signature" => "the payer has not signed yet",
    "wrong_mode" => "this operation doesn't match the payment's mode (authorize vs charge)",
    "already_disputed" => "a dispute is already open — close it first",
    "not_disputed" => "there is no open dispute to close",
    "nothing_to_dispute" => "a dispute needs a merchant-held (refundable) balance",
    "unknown_dispute_reason" => "reason must be a dispute-reason code (Rail0::DisputeReasons.codes(:open) / codes(:close)) or exactly its bytes32 — full_refund is system-only",
    "transaction_not_overwritable" => "a transaction for this operation is already in flight — wait for it to settle",
    "signer_mismatch" => "the signature recovers to a different wallet than the one that must sign — the payment's payer/payee, or at POST /claim the wallet the onboarding request names",
    # The SIWE BINDING failures, split out of signer_mismatch so a failed login says
    # WHICH part of the proof did not bind (#216). None names the server's own
    # expectation: that endpoint is unauthenticated, so echoing the allow-list would
    # turn every hint into a probe. siwe_chain_mismatch may point at GET /blockchains:
    # the accepted chain ids (1 plus every active catalog chain) are public there anyway.
    "siwe_domain_not_allowed" => "sign with the origin the front-end is served from, and have it added to the gateway's SIWE domain allow-list",
    "siwe_uri_mismatch" => "the message's uri host must equal its own domain",
    "siwe_chain_mismatch" => "sign with chain id 1 (what the SDK's signing helpers send) or the id of a chain the gateway has active (GET /blockchains) - usually a hand-built message or a wallet on an unsupported or deactivated network",
    "siwe_proof_expired" => "get a fresh nonce and sign again",
    # Address-wide, not one token: "sign in again", not "that token is dead".
    "sessions_revoked" => "every session issued before this address's revoke-all cutoff is refused - sign in again",
    "config_hash_mismatch" => "the payment record and its on-chain deployment disagree — the payment cannot be operated as recorded",
    "payment_not_on_chain" => "the contract has no record of this payment — its opening transaction may never have confirmed",
    "unsupported_contract_version" => "the payment's RAIL0 deployment is newer or older than this gateway supports — upgrade the gateway",
    "insufficient_token_balance" => "the paying wallet does not hold enough of the token — top it up and retry",
    "invalid_token_signature" => "the EIP-3009 authorization did not recover to the paying wallet — wrong key, chain, token or amount",
    "authorization_already_used" => "that EIP-3009 authorization was already spent or cancelled — each is single-use, create a fresh payment",
    "authorization_not_yet_valid" => "the authorization's validAfter is still in the future",
    "token_account_blocked" => "the token issuer has blocklisted one of the wallets in this transfer",
    "token_paused" => "the token contract is paused by its issuer — no transfer can settle right now",
    "insufficient_gas_funds" => "the sending wallet cannot cover gas — fund it with the chain's native token",
    "nonce_too_low" => "a transaction with that nonce is already on-chain — re-prepare the operation",
    "replacement_underpriced" => "another transaction with that nonce is pending and this one does not pay enough to replace it",
    "gas_price_too_low" => "the fee is below what the node accepts — re-prepare to pick up current fees",
    "already_known" => "the node already has this exact transaction — wait for it to confirm rather than resending",
    "rpc_unavailable" => "no configured RPC endpoint answered — the transaction was not submitted",
    "not_the_payee" => "only the payment's payee can do this — sign in with the merchant's wallet",
    "not_the_payer" => "only the payment's payer can do this — sign in with the buyer's wallet",
    "not_a_participant" => "only the payer and the payee can see or act on a payment",
    "not_payee" => "only the merchant (payee) may do this",
    "not_payer" => "only the buyer (payer) may do this",
    "not_payer_or_payee" => "only the payer or the payee may do this",
    "release_submitter_not_a_party" => "a release must be sent by the payment's payer or payee — omit `from` to build it for the signed-in wallet",
    "payer_must_be_caller" => "the payer must be the signed-in wallet — sign in as the buyer to create its payment",
    # gateway#439: a deactivated session may switch its OWN wallet back on when its owner
    # switched it off; an operator's switch-off is the operator's to lift.
    "wallet_deactivated" => "this wallet is deactivated: it can still read, but not act on payments or change the account — if you switched it off, its own session can switch it back on (wallets.update(..., active: true)), or sign in with another of the account's wallets",
    "wallet_deactivated_by_operator" => "an operator deactivated this wallet, so only an operator can reactivate it — ask an operator to reactivate it",
    "account_deactivated" => "the merchant account is deactivated: void, release and refund still work, but authorize, charge, capture and account changes do not — ask an operator to reactivate it",
    # A session is bound to the one wallet it signed in with: the account's other wallets
    # are readable, but not this session's to change (operators are exempt).
    "not_your_wallet" => "a session can change only the wallet it signed in with — sign in with that wallet to update it, deactivate it or manage its tokens",
    # POST /accounts/:id/wallets is suspended for every session until the merchant
    # wallet-management section lands.
    "wallet_add_unavailable" => "adding a wallet to an account is not available yet — it returns with the merchant wallet-management section",
    # Login resolves the account FROM a wallet, so an account left with no active one
    # could neither act nor add a wallet back. Adding a wallet is suspended and a session
    # changes only its own wallet, so the other wallet comes back on from its own session
    # (if its owner switched it off) or from an operator (gateway#439).
    "last_active_wallet" => "this is the account's only active wallet — another wallet must be active before this one can be switched off: sign in with one you switched off and reactivate it, or ask an operator (adding a wallet is not available yet)",
    "last_admin" => "the change would leave no active operator — grant the operator role to another active account first",
    "not_redrivable" => "only a pending transaction that already holds its signed bytes can be redriven — check the transaction's `redrivable` flag, and submit the signature if it has none",
    "refund_expired" => "the refund window has closed (refundExpiry passed) — refund/dispute is no longer possible",
    "authorization_not_expired" => "release opens only after authorizationExpiry — wait until it passes",
    "already_captured" => "already (partially) captured — use release for the remainder, not void",
    "token_not_accepted" => "the token isn't in this deployment's allowlist",
    "payment_already_exists" => "a payment with this id already exists on-chain",
    # Ported from rail0-go, which had drifted five codes ahead of this table (#13).
    "unsupported_payment_method" => "the payee (merchant) doesn't accept this token/chain — check the merchant's payment methods",
    "idempotency_key_reused" => "that Idempotency-Key was already used for a payment with different terms — reuse it only to retry the same request, or pick a new key",
    "unknown_token" => "the token isn't configured on this chain",
    "no_active_contract" => "no active RAIL0 contract on that chain",
    "missing_param" => "a required parameter is missing from the request",
    # Ported from rail0-go / rail0-ts, which carried these five and this table did not.
    "validation_failed" => "a parameter is invalid — the error detail names the offending field",
    "invalid_sort" => "that field cannot be sorted on — the error detail names the allowed set",
    "rate_limited" => "rate limit reached — wait for Retry-After (the time left in the window) and retry",
    "event_not_found" => "the reported transaction mined but did not perform this operation on this payment — nothing moved; check the hash and prepare the operation again",
    "submission_timeout" => "the transaction was not mined in time and was recorded as failed — if it mines later, re-report its hash via the operation's submitted endpoint",
    # From the gateway's error catalog (lib/rail0/error_catalog.rb).
    "invalid_signature" => "the signature could not be recovered — it is malformed, truncated or has a bad recovery byte; send the 65-byte 0x hex (r || s || v) the signer produced",
    "nonce_used" => "that sign-in nonce was already consumed — request a fresh one (auth.nonce); each is single-use",
    "siwe_purpose_mismatch" => "the signed message's statement is for a different flow — login, wallet registration, account claim and revoke-all each need their own exact statement",
    "transaction_mismatch" => "the submitted transaction's target, calldata, value or chain differs from the one this operation prepared — sign the prepare's unsigned_transaction unmodified",
    "signing_payload_unavailable" => "the gateway could not build the payer's authorization payload because a chain read failed — retry in a moment (payments.get returns it once available)",
    "queue_unavailable" => "the gateway's job queue could not be reached, so nothing was enqueued — retry in a moment",
    "webhook_limit_reached" => "this account already holds the most webhook subscriptions it may have — delete one, or add topics to an existing subscription",
    # Onboarding: POST /signup and POST /claim (the gateway's onboarding flow).
    # The /admin/onboardings codes (onboarding_not_found, onboarding_completed) are left
    # out: those routes are the console's, not the SDK's. The link codes never say which
    # term failed — a stale link has one remedy: the newest email, or a new link.
    "signup_unavailable" => "self-service sign-up is switched off on this gateway for now — try again later, or ask your RAIL0 contact for an invite",
    "onboarding_unavailable" => "this gateway has no onboarding secret configured, so it can neither issue nor verify sign-up links — ask the operator",
    "email_provider_not_configured" => "the gateway has no email provider that delivers, so no link was sent and nothing was saved — ask the operator to configure one",
    "email_domain_not_allowed" => "this environment emails only its allowed domains (the detail lists them) — use an address on one of them; nothing was saved",
    "account_email_taken" => "an account with this email already exists — sign in with its wallet, or use another email",
    "account_wallet_taken" => "this wallet is already registered to an account — sign in with it, or use another wallet",
    "account_name_taken" => "an account with this name already exists — choose another name",
    "terms_required" => "the claim needs terms_version: send the version of the terms the merchant accepted",
    "onboarding_link_invalid" => "the link was altered or its request no longer exists — use the link in the most recent email, or ask for a new one",
    "onboarding_link_expired" => "the link has expired — sign up again, or ask your RAIL0 contact for a new link",
    "onboarding_link_superseded" => "a newer link was sent for this request and this one no longer works — use the link in the most recent email",
    # Payouts (gateway#455): the merchant's transfer of its balance to a payout destination.
    "confirmation_required" => "registering a payout destination, or changing its min_amount or no_minimum, needs confirm_details: true — the merchant's confirmation that they checked the address, network, token and minimum deposit at the venue (PayoutDestinations::CONFIRM_DETAILS_TEXT)",
    "payout_destination_exists" => "this wallet already has a destination with this address for this token and chain — use it (payout_destinations.list)",
    "payout_destination_zero_address" => "the zero address cannot receive a payout — register the venue's deposit address",
    "payout_destination_own_wallet" => "the destination is the paying wallet itself — register the deposit address of the exchange, Circle Mint account or another wallet you control",
    "payout_destination_is_contract" => "the address is a RAIL0 contract or a token contract on this chain, where funds cannot be recovered — register the venue's deposit address",
    "payout_destination_disabled" => "the destination is disabled — re-enable it (payout_destinations.update(id, active: true)) or choose another one",
    "payout_destination_unverified" => "the destination is not verified: send the proof (payouts.prepare(purpose: \"proof\")), wait for it to confirm, check the venue credited it, then payout_destinations.confirm — until then only the proof amount can be sent",
    "payout_destination_proof_missing" => "the proof transfer has not confirmed on-chain yet — prepare, sign and submit it (purpose: \"proof\"), wait for payouts.get to say confirmed, then confirm the destination",
    "minimum_required" => "a payout destination needs its venue's minimum deposit: min_amount (base units, from the venue's deposit page), or no_minimum: true when the venue has none — a blank min_amount is not one (to remove a minimum, send no_minimum: true)",
    "minimum_conflict" => "min_amount and no_minimum: true contradict each other — send the venue's minimum, or no_minimum: true when it has none, not both",
    "payout_below_minimum" => "the amount is below the destination's min_amount (the venue may never credit it) — send at least the minimum; for \"all\", the balance after the reserve is below it",
    "insufficient_balance" => "the wallet does not hold enough of the token for this amount after the refund reserve — the detail names what is available",
    "payout_limit_reached" => "this wallet reached its hourly payout limit — retry later",
    "payout_already_signed" => "the payout already holds a signed transaction that may still be mined — resend it (payouts.resend) and let it settle; it cannot be re-prepared or cancelled",
    "payout_not_pending" => "the payout is already submitted or settled — prepare a new one",
    "payout_not_signed" => "the payout holds no signed transaction to resend — submit the signed transfer first",
    "payout_hash_in_use" => "another payout already records this transaction hash — one transaction settles one payout",
    "foreign_transfer_hash" => "the reported transaction does not move this payout's amount of its token to its destination — report the hash of the transfer you broadcast for this payout",
    "invalid_amount" => "the amount is not valid: base units (digits only, below 2^120) for reserve_amount/min_amount, a positive decimal within the token's decimals elsewhere",
    "invalid_transaction" => "the signed transaction could not be decoded, or its sender is not allowed here — sign the prepare's unsigned_transaction unmodified with the right wallet",
    "unknown_chain" => "that chain id is not configured on this gateway — see chains.list",
    # A BARE forbidden is not a party mismatch: the gateway split those into codes of
    # their own (not_the_payee, not_the_payer, wallet_deactivated, account_deactivated,
    # not_your_account) because they need different fixes. This entry kept describing
    # one of them long after the split — and the rule it named no longer exists in the
    # gateway at all.
    "forbidden" => "not permitted for this session — typically the operator grant, a resource owned by another account, or a transaction signed by the wrong wallet"
  }.freeze

  # An actionable hint for a rail0 error code, or nil when the code is unknown.
  # @param code [String, nil]
  # @return [String, nil]
  def self.describe_error(code)
    return nil if code.nil? || code.to_s.empty?

    ERROR_HINTS[code.to_s]
  end
end
