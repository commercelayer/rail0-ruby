# frozen_string_literal: true

module Rail0
  module Resources
    class Payments
      def initialize(http)
        @http = http
      end

      # Create a payment intent. Returns the EIP-712 signingPayload for the payer to sign.
      # @param params [Hash] payment (PaymentInput), chain_id, mode
      # @return [Hash] rail0_id, config_hash, payment, chain_id, rail0_contract, signing_prepare
      def create(params)
        @http.post("/payments", params)
      end

      # Fetch current payment state (DB status + live on-chain amounts).
      # @param payment_id [String] bytes32 payment identifier
      # @return [Hash] rail0_id, status, mode, amount, payer, payee, token, transactions, …
      def get(payment_id)
        @http.get("/payments/#{payment_id}")
      end

      # List payments for the authenticated wallet (requires JWT).
      # @return [Array<Hash>]
      def list
        @http.get("/payments")
      end

      # Submit the payer's EIP-712 signature.
      # @param payment_id [String]
      # @param params [Hash] signature (65-byte 0x-prefixed hex)
      # @return [Hash] rail0_id, status, recovered_payer
      def sign(payment_id, params)
        @http.put("/payments/#{payment_id}/sign", params)
      end

      # ── Authorize ────────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned authorize() transaction.
      # Creates a Transaction row with status pending.
      # @return [Hash] unsigned_transaction, to, data, chain_id, nonce, …
      def authorize_prepare(payment_id)
        @http.post("/payments/#{payment_id}/authorize/prepare")
      end

      # Phase 2 — Submit the signed authorize transaction (HTTP 202).
      # Poll #get until status == "authorized".
      # @param params [Hash] signed_transaction (0x-prefixed RLP hex)
      def authorize(payment_id, params)
        @http.post("/payments/#{payment_id}/authorize", params)
      end

      # ── Charge ───────────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned charge() transaction (authorize+capture, no escrow).
      def charge_prepare(payment_id)
        @http.post("/payments/#{payment_id}/charge/prepare")
      end

      # Phase 2 — Submit the signed charge transaction.
      # Poll #get until status == "charged".
      def charge(payment_id, params)
        @http.post("/payments/#{payment_id}/charge", params)
      end

      # ── Capture ──────────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned capture() transaction.
      # @param params [Hash] amount (Uint256String)
      def capture_prepare(payment_id, params)
        @http.post("/payments/#{payment_id}/capture/prepare", params)
      end

      # Phase 2 — Submit the signed capture transaction.
      # Poll #get until status == "captured" or "partially_captured".
      def capture(payment_id, params)
        @http.post("/payments/#{payment_id}/capture", params)
      end

      # ── Void ─────────────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned void() transaction.
      def void_prepare(payment_id)
        @http.post("/payments/#{payment_id}/void/prepare")
      end

      # Phase 2 — Submit the signed void transaction.
      # Poll #get until status == "voided".
      def void(payment_id, params)
        @http.post("/payments/#{payment_id}/void", params)
      end

      # ── Release ──────────────────────────────────────────────────────────────

      # Phase 1 — Build the unsigned release() transaction.
      # @param params [Hash] caller_address (optional, defaults to payee)
      def release_prepare(payment_id, params = {})
        @http.post("/payments/#{payment_id}/release/prepare", params)
      end

      # Phase 2 — Submit the signed release transaction.
      # Poll #get until status == "released".
      def release(payment_id, params)
        @http.post("/payments/#{payment_id}/release", params)
      end

      # ── Refund (EIP-3009) ────────────────────────────────────────────────────

      # Phase 1a — Request the EIP-3009 signing payload for the payee.
      # Call with only amount; the payee signs the returned signing_prepare.
      #
      # Phase 1b — Build the unsigned refund() transaction.
      # Call again with amount + v, r, s (from the signed EIP-3009 payload).
      # Returns unsigned_transaction with the EIP-3009 signature embedded.
      #
      # No ERC-20 approve() needed — refund uses receiveWithAuthorization.
      # @param params [Hash] amount + optional (v, r, s)
      def refund_prepare(payment_id, params)
        @http.post("/payments/#{payment_id}/refund/prepare", params)
      end

      # Phase 2 — Submit the signed refund transaction.
      # Poll #get until status == "refunded" or "partially_refunded".
      def refund(payment_id, params)
        @http.post("/payments/#{payment_id}/refund", params)
      end
    end
  end
end
