# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Payment lifecycle operations.
    #
    # Every on-chain operation is two-phase: a +*_prepare+ call returns an unsigned
    # EIP-1559 transaction (sign it locally with {Rail0::Signing.sign_transaction}),
    # then the matching submit call broadcasts the signed raw tx (HTTP 202, async —
    # poll {get} until the status settles). Wallets that sign and broadcast in one
    # step (e.g. MetaMask) skip the local signer and report the hash via
    # {submit_by_hash} instead.
    class Payments
      include Query

      # Operations accepted by the prepare/submit endpoints.
      OPERATIONS = %w[authorize capture charge void release refund].freeze

      def initialize(http)
        @http = http
      end

      # List payments for the authenticated wallet (requires JWT). Returns
      # payments where the caller is the payer or payee.
      # @param status [String, nil] Filter by payment status.
      # @param mode [String, nil] Filter by mode ("authorize" or "charge").
      # @param payer [String, nil] Filter by payer address.
      # @param payee [String, nil] Filter by payee address.
      # @param token [String, nil] Filter by token contract address.
      # @param rail0_id [String, nil] Filter by the logical on-chain payment id (0x…).
      # @param chain_id [Integer, nil] Filter by the payment's chain.
      # @param disputed [Boolean, nil] Filter by whether an open dispute exists.
      # @param min_amount [String, nil] Minimum amount in token base units (inclusive).
      # @param max_amount [String, nil] Maximum amount in token base units (inclusive).
      # @param created_from [String, nil] Only payments created at/after this ISO-8601 time.
      # @param created_to [String, nil] Only payments created at/before this ISO-8601 time.
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def list(status: nil, mode: nil, payer: nil, payee: nil, token: nil, rail0_id: nil,
               chain_id: nil, disputed: nil, min_amount: nil, max_amount: nil,
               created_from: nil, created_to: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(status: status, mode: mode, payer: payer, payee: payee, token: token,
                            rail0_id: rail0_id, chain_id: chain_id, disputed: disputed,
                            min_amount: min_amount, max_amount: max_amount,
                            created_from: created_from, created_to: created_to,
                            sort: sort, page: page, per_page: per_page)
        @http.get_list("/payments#{query}")
      end

      # Create a payment. Returns the record — when still unsigned it embeds the
      # EIP-3009 +signing_payload+ for the payer to sign.
      #
      # Pass +idempotency_key+ to make the request replay-safe: a repeated call
      # with the same key returns the existing payment (HTTP 200) instead of
      # creating a new one.
      #
      # Accepts either a params Hash or keyword fields:
      #   create(chain_id: 84532, mode: "authorize", amount: "100000000", token: "0x…", payer: "0x…", payee: "0x…")
      #   create({ chain_id: 84532, ... }, idempotency_key: "order-42")
      #
      # @param params [Hash, nil] chain_id, mode, amount, token, payer, payee, description (opt), metadata (opt).
      # @param idempotency_key [String, nil] Optional Idempotency-Key header value.
      # @param fields [Hash] Field keywords, used when +params+ is omitted.
      # @return [Hash]
      def create(params = nil, idempotency_key: nil, **fields)
        body    = params || fields
        headers = idempotency_key ? { "Idempotency-Key" => idempotency_key } : {}
        @http.post("/payments", body, headers: headers)
      end

      # Fetch current payment state (DB status + live on-chain amounts + transactions).
      # @param id [String] Payment UUID or rail0_id.
      # @return [Hash]
      def get(id)
        @http.get("/payments/#{id}")
      end

      # List on-chain transactions for a payment.
      # @param id [String] Payment UUID or rail0_id.
      # @param operation [String, nil] Filter by operation (see {OPERATIONS}).
      # @param status [String, nil] Filter by transaction status.
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def transactions(id, operation: nil, status: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(operation: operation, status: status, sort: sort, page: page, per_page: per_page)
        @http.get_list("/payments/#{id}/transactions#{query}")
      end

      # Submit the payer's EIP-712 signature (PUT /payments/{id}/sign).
      # @param id [String] Payment UUID or rail0_id.
      # @param params [Hash] { signature: "0x…" } (65-byte 0x-prefixed hex).
      # @return [Hash]
      def sign(id, params)
        @http.put("/payments/#{id}/sign", params)
      end

      # List a payment's dispute open/close history.
      # @param id [String] Payment UUID or rail0_id.
      # @param status [String, nil] Filter by dispute status ("open" or "closed").
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def disputes(id, status: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(status: status, sort: sort, page: page, per_page: per_page)
        @http.get_list("/payments/#{id}/disputes#{query}")
      end

      # ── Generic prepare / submit ─────────────────────────────────────────────

      # Build the unsigned transaction for an operation
      # (POST /payments/{id}/{op}/prepare). +body+ carries operation-specific
      # fields: amount (capture, refund), signature (refund phase-2), from
      # (release). On the refund prepare, omitting the signature returns the
      # EIP-3009 signing payload (refund phase-1) instead of an unsigned tx.
      # @param id [String] Payment UUID or rail0_id.
      # @param operation [String] One of {OPERATIONS}.
      # @param body [Hash, nil] Operation-specific fields.
      # @return [Hash]
      def prepare(id, operation, body = nil)
        @http.post("/payments/#{id}/#{operation}/prepare", body)
      end

      # Broadcast a signed transaction for an operation (POST /payments/{id}/{op}); HTTP 202.
      # @param id [String] Payment UUID or rail0_id.
      # @param operation [String] One of {OPERATIONS}.
      # @param params [Hash] { signed_transaction: "0x…" }.
      # @return [Hash]
      def submit(id, operation, params)
        @http.post("/payments/#{id}/#{operation}", params)
      end

      # Record a transaction the caller broadcast themselves (MetaMask/wallet flow)
      # for an operation (POST /payments/{id}/{op}/submitted); HTTP 202.
      # @param id [String] Payment UUID or rail0_id.
      # @param operation [String] One of {OPERATIONS}.
      # @param params [Hash] { transaction_hash: "0x…" }.
      # @return [Hash]
      def submit_by_hash(id, operation, params)
        @http.post("/payments/#{id}/#{operation}/submitted", params)
      end

      # ── Per-operation convenience wrappers ───────────────────────────────────

      # Phase 1 — build the unsigned authorize() transaction (escrow hold).
      def authorize_prepare(id)
        prepare(id, "authorize")
      end

      # Phase 2 — submit the signed authorize transaction.
      def authorize(id, params)
        submit(id, "authorize", params)
      end

      # Phase 1 — build the unsigned charge() transaction (one-shot authorize+capture).
      def charge_prepare(id)
        prepare(id, "charge")
      end

      # Phase 2 — submit the signed charge transaction.
      def charge(id, params)
        submit(id, "charge", params)
      end

      # Phase 1 — build the unsigned capture() transaction. +amount+ is required.
      def capture_prepare(id, amount)
        prepare(id, "capture", { amount: amount })
      end

      # Phase 2 — submit the signed capture transaction.
      def capture(id, params)
        submit(id, "capture", params)
      end

      # Phase 1 — build the unsigned void() transaction. Valid only while nothing
      # has been captured yet; after any capture the contract reverts AlreadyCaptured
      # (use {release_prepare} to return the uncaptured remainder instead).
      def void_prepare(id)
        prepare(id, "void")
      end

      # Phase 2 — submit the signed void transaction.
      def void(id, params)
        submit(id, "void", params)
      end

      # Phase 1 — build the unsigned release() transaction. +from+ overrides the
      # submitter address (defaults to the payer). Returns uncaptured escrow to the
      # payer.
      def release_prepare(id, from: nil)
        prepare(id, "release", from ? { from: from } : {})
      end

      # Phase 2 — submit the signed release transaction.
      def release(id, params)
        submit(id, "release", params)
      end

      # Two-phase EIP-3009 refund.
      # Phase 1: pass only +amount+ → returns a signing payload for the payee to sign.
      # Phase 2: pass +amount+ and +signature+ → returns the unsigned refund tx.
      # @param id [String] Payment UUID or rail0_id.
      # @param amount [String] Amount to refund (token base units).
      # @param signature [String, nil] Payee's EIP-3009 signature (0x…), phase 2 only.
      # @return [Hash]
      def refund_prepare(id, amount:, signature: nil)
        body = { amount: amount }
        body[:signature] = signature unless signature.nil?
        prepare(id, "refund", body)
      end

      # Phase 2 — submit the signed refund transaction.
      def refund(id, params)
        submit(id, "refund", params)
      end

      # ── Disputes (payer-driven, signal-only) ─────────────────────────────────
      #
      # Disputes follow the same prepare → submit lifecycle, but are payer-driven
      # and authorized on-chain (no JWT): prepare returns the unsigned tx, the payer
      # signs and submits the signed raw tx, and the on-chain event flips the
      # payment's +disputed+ flag.

      # Phase 1 — build the unsigned dispute() transaction (payer only).
      # @param id [String] Payment UUID or rail0_id.
      # @param reason [String, nil] Optional bytes32 code (0x…); defaults to zero server-side.
      # @return [Hash]
      def dispute_prepare(id, reason: nil)
        prepare_dispute("dispute/prepare", id, reason)
      end

      # Phase 2 — submit the signed dispute transaction (payer only).
      # @param id [String] Payment UUID or rail0_id.
      # @param params [Hash] { signed_transaction: "0x…" }.
      # @return [Hash]
      def dispute(id, params)
        @http.post("/payments/#{id}/dispute", params)
      end

      # Phase 1 — build the unsigned closeDispute() transaction (payer only).
      # @param id [String] Payment UUID or rail0_id.
      # @param reason [String, nil] Optional bytes32 code (0x…).
      # @return [Hash]
      def close_dispute_prepare(id, reason: nil)
        prepare_dispute("dispute/close/prepare", id, reason)
      end

      # Phase 2 — submit the signed close-dispute transaction (payer only).
      # @param id [String] Payment UUID or rail0_id.
      # @param params [Hash] { signed_transaction: "0x…" }.
      # @return [Hash]
      def close_dispute(id, params)
        @http.post("/payments/#{id}/dispute/close", params)
      end

      private

      # POST a dispute prepare with the optional {reason} body shared by the open
      # and close prepares.
      def prepare_dispute(path, id, reason)
        body = reason ? { reason: reason } : {}
        @http.post("/payments/#{id}/#{path}", body)
      end
    end
  end
end
