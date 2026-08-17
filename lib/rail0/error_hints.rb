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
    "transaction_not_overwritable" => "a transaction for this operation is already in flight — wait for it to settle",
    "signer_mismatch" => "the signing key doesn't match the payment's payer/payee",
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
    "forbidden" => "not permitted for this session — on create the payer must be the signed-in address"
  }.freeze

  # An actionable hint for a rail0 error code, or nil when the code is unknown.
  # @param code [String, nil]
  # @return [String, nil]
  def self.describe_error(code)
    return nil if code.nil? || code.to_s.empty?

    ERROR_HINTS[code.to_s]
  end
end
