# GENERATED — DO NOT EDIT. Run `ruby gen/generate.rb` to regenerate.
# frozen_string_literal: true

require "cgi"

module Rail0
  module Resources
    class Payments
      def initialize(http)
        @http = http
      end

      # List payments for the authenticated wallet (requires JWT).
      # @param status [String, nil] Filter by payment status.
      # @param mode [String, nil] Filter by mode ("authorize" or "charge").
      # @param payer [String, nil] Filter by payer Ethereum address.
      # @param payee [String, nil] Filter by payee Ethereum address.
      # @param token [String, nil] Filter by token contract address.
      # @param page [Integer] Page number (1-based, default 1).
      # @param per_page [Integer] Items per page (default 20, max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def list(status: nil, mode: nil, payer: nil, payee: nil, token: nil, page: nil, per_page: nil)
        query = build_query(status: status, mode: mode, payer: payer, payee: payee,
                            token: token, page: page, per_page: per_page)
        @http.get("/payments#{query}")
      end

      # Create a payment intent. Returns the EIP-712 signingPayload for the payer to sign.
      # @param params [Hash] chain_id, mode, amount, token, payer, payee, description (optional), metadata (optional)
      # @return [Hash] rail0_id, config_hash, payment, chain_id, rail0_contract, signing_payload
      def create(params)
        @http.post("/payments", params)
      end

      # Fetch current payment state (DB status + live on-chain amounts).
      # @param rail0_id [String] bytes32 payment identifier.
      # @return [Hash]
      def get(rail0_id)
        @http.get("/payments/#{rail0_id}")
      end

      # List on-chain transactions for a payment.
      # @param rail0_id [String] bytes32 payment identifier.
      # @param operation [String, nil] Filter by operation type.
      # @param status [String, nil] Filter by transaction status.
      # @param page [Integer] Page number (1-based, default 1).
      # @param per_page [Integer] Items per page (default 20, max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def transactions(rail0_id, operation: nil, status: nil, page: nil, per_page: nil)
        query = build_query(operation: operation, status: status, page: page, per_page: per_page)
        @http.get("/payments/#{rail0_id}/transactions#{query}")
      end

      # Submit the payer's EIP-712 signature.
      # @param rail0_id [String] bytes32 payment identifier.
      # @param params [Hash] signature (65-byte 0x-prefixed hex).
      # @return [Hash] rail0_id, status, recovered_payer
      def sign(rail0_id, params)
        @http.put("/payments/#{rail0_id}/sign", params)
      end

      # ── Authorize ────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned authorize() transaction.
      # @param rail0_id [String]
      # @return [Hash] unsigned_transaction, to, data, chain_id, nonce, …
      def authorize_prepare(rail0_id)
        @http.post("/payments/#{rail0_id}/authorize/prepare")
      end

      # Phase 2 — Submit the signed authorize transaction (HTTP 202).
      # @param rail0_id [String]
      # @param params [Hash] signed_transaction (0x-prefixed RLP hex).
      # @return [Hash] rail0_id, status
      def authorize(rail0_id, params)
        @http.post("/payments/#{rail0_id}/authorize", params)
      end

      # ── Charge ───────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned charge() transaction (authorize+capture, no escrow).
      # @param rail0_id [String]
      # @return [Hash]
      def charge_prepare(rail0_id)
        @http.post("/payments/#{rail0_id}/charge/prepare")
      end

      # Phase 2 — Submit the signed charge transaction.
      # @param rail0_id [String]
      # @param params [Hash] signed_transaction
      # @return [Hash] rail0_id, status
      def charge(rail0_id, params)
        @http.post("/payments/#{rail0_id}/charge", params)
      end

      # ── Capture ──────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned capture() transaction.
      # @param rail0_id [String]
      # @param params [Hash] amount (Uint256String)
      # @return [Hash]
      def capture_prepare(rail0_id, params)
        @http.post("/payments/#{rail0_id}/capture/prepare", params)
      end

      # Phase 2 — Submit the signed capture transaction.
      # @param rail0_id [String]
      # @param params [Hash] signed_transaction
      # @return [Hash] rail0_id, status
      def capture(rail0_id, params)
        @http.post("/payments/#{rail0_id}/capture", params)
      end

      # ── Void ─────────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned void() transaction.
      # @param rail0_id [String]
      # @return [Hash]
      def void_prepare(rail0_id)
        @http.post("/payments/#{rail0_id}/void/prepare")
      end

      # Phase 2 — Submit the signed void transaction.
      # @param rail0_id [String]
      # @param params [Hash] signed_transaction
      # @return [Hash] rail0_id, status
      def void(rail0_id, params)
        @http.post("/payments/#{rail0_id}/void", params)
      end

      # ── Release ──────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned release() transaction.
      # @param rail0_id [String]
      # @param params [Hash] optional caller_address
      # @return [Hash]
      def release_prepare(rail0_id, params = {})
        @http.post("/payments/#{rail0_id}/release/prepare", params)
      end

      # Phase 2 — Submit the signed release transaction.
      # @param rail0_id [String]
      # @param params [Hash] signed_transaction
      # @return [Hash] rail0_id, status
      def release(rail0_id, params)
        @http.post("/payments/#{rail0_id}/release", params)
      end

      # ── Refund (EIP-3009) ────────────────────────────────────────────────

      # Two-phase EIP-3009 refund flow.
      # Phase 1: call with only amount — returns a signing payload.
      # Phase 2: call with amount + signature — returns unsigned refund transaction.
      # @param rail0_id [String]
      # @param amount [String] Uint256String amount to refund.
      # @param signature [String, nil] 0x-prefixed hex signature (phase 2 only).
      # @return [Hash]
      def refund_prepare(rail0_id, params = {})
        @http.post("/payments/#{rail0_id}/refund/prepare", params)
      end

      # Phase 2 — Submit the signed refund transaction.
      # @param rail0_id [String]
      # @param params [Hash] signed_transaction
      # @return [Hash] rail0_id, status
      def refund(rail0_id, params)
        @http.post("/payments/#{rail0_id}/refund", params)
      end

      private

      def build_query(**params)
        pairs = params.compact.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }
        pairs.empty? ? "" : "?#{pairs.join("&")}"
      end
    end
  end
end
